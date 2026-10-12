import AppKit
import MetalKit
import MetalPerformanceShaders
import CoreVideo

let foldShader = """
#include <metal_stdlib>
using namespace metal;
struct Vertex { float4 position [[position]]; float2 uv; };
struct Params { float progress; float softness; float2 texel; float2 viewport; float motion; float padding; };
vertex Vertex foldVertex(uint i [[vertex_id]]) {
    const float2 p[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    Vertex v; v.position=float4(p[i],0,1); v.uv=float2((p[i].x+1)*.5, (1-p[i].y)*.5); return v;
}
fragment float4 foldFragment(Vertex v [[stage_in]], texture2d<float> screen [[texture(0)]],
                              texture2d<float> nearBlur [[texture(1)]], texture2d<float> midBlur [[texture(2)]],
                              texture2d<float> farBlur [[texture(3)]],
                              constant Params &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float amount=clamp(p.progress,0.0f,1.0f);
    // The open endpoint is an exact copy, including the outermost pixels.
    if(amount<.0001) return float4(screen.sample(s,v.uv).rgb,1);
    float theta=amount*1.555;
    float cosine=cos(theta), sine=sin(theta), perspective=.30*sine;
    float baseBow=.105*sine;
    float bowLimit=.8*cosine/(1+perspective);
    float bow=baseBow*rsqrt(1+pow(baseBow/max(bowLimit,.0001f),2.0));
    float height=1-v.uv.y;
    // Invert the projection of a gently curved sheet, anchored to the hinge.
    float a=cosine+bow-height*perspective;
    float discriminant=a*a-4*bow*height;
    float ambient=amount*amount*.008;
    float glow=exp(-pow((v.uv.x-.5)*1.4,2.0)-pow((v.uv.y-.90)*3.0,2.0));
    float3 background=float3(.42,.57,.62)*ambient*glow;
    if(discriminant<0 || a<=0) return float4(background,1);
    float q=2*height/(a+sqrt(max(discriminant,0.0f)));
    float scale=1+q*perspective;
    float2 uv=float2(.5+(v.uv.x-.5)*scale,1-q);
    // Rounded corners and analytic antialiasing stay consistent on Retina.
    float2 size=1/p.texel;
    float radius=21*(size.x/1280)*smoothstep(0.0,.24,amount);
    float2 position=(uv-.5)*size;
    float2 d=abs(position)-(size*.5-radius);
    float distance=length(max(d,0.0f))+min(max(d.x,d.y),0.0f)-radius;
    float aa=max(fwidth(distance),.5f);
    float coverage=1-smoothstep(-aa*.5,aa*.5,distance);
    if(coverage<=0) return float4(background,1);
    float depth=clamp(q,0.0f,1.0f);
    // Blend three optical radii continuously; no previous frames or ghost trails.
    float exposure=clamp(p.motion,0.0f,1.0f)*.085*smoothstep(0.0,.12,amount);
    float focus=(smoothstep(.045,.88,amount)+exposure)*max(p.softness,0.0f)*(.16+.84*pow(depth,1.6));
    float3 sharp=screen.sample(s,uv).rgb;
    float3 soft=nearBlur.sample(s,uv).rgb;
    float3 medium=midBlur.sample(s,uv).rgb;
    float3 diffuse=farBlur.sample(s,uv).rgb;
    float3 color=mix(sharp,soft,smoothstep(0.0,.18,focus));
    color=mix(color,medium,smoothstep(.10,.55,focus));
    color=mix(color,diffuse,smoothstep(.38,1.18,focus));
    float hingeShade=exp(-depth*28)*sine*.13;
    float falloff=amount*amount*(.10+.18*depth);
    color*=1-falloff-hingeShade;
    // A broad, quiet reflection moves across the surface as the hinge turns.
    float band=exp(-pow((depth-(.90-.43*amount))/.32,2.0));
    float fresnel=pow(sine,3.0);
    color+=float3(.88,.91,.94)*band*(sine*.025+fresnel*.020);
    float edgeLight=exp(-abs(distance)/max(aa*1.15,1.0f))*sine;
    float topLight=smoothstep(.68,.99,depth);
    color+=float3(.77,.84,.90)*edgeLight*(.045+.065*topLight);
    float settle=1-smoothstep(.955,1.0,amount);
    color*=settle;
    return float4(mix(background,color,coverage),1);
}
"""

struct FoldParams {
    var progress: Float
    var softness: Float
    var texel: SIMD2<Float>
    var viewport: SIMD2<Float>
    var motion: Float = 0
    var padding: Float = 0
}

final class FoldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var texture: MTLTexture? { didSet { blurDirty = true } }
    var progress: Float = 0
    var softness: Float = 1
    var motion: Float = 0
    private var cache: CVMetalTextureCache?
    private var retainedFrame: CVPixelBuffer?
    private var retainedTexture: CVMetalTexture?
    private var nearKernel: MPSImageGaussianBlur
    private var midKernel: MPSImageGaussianBlur
    private var farKernel: MPSImageGaussianBlur
    private let downsample: MPSImageBilinearScale
    private var reducedTexture: MTLTexture?
    private var nearTexture: MTLTexture?
    private var midTexture: MTLTexture?
    private var farTexture: MTLTexture?
    private var blurDirty = true
    private let inFlight = DispatchSemaphore(value: 2)

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("This Mac does not support Metal.")
        }
        self.device = device; self.queue = queue
        downsample = MPSImageBilinearScale(device: device)
        nearKernel = MPSImageGaussianBlur(device: device, sigma: 1.1)
        midKernel = MPSImageGaussianBlur(device: device, sigma: 3.25)
        farKernel = MPSImageGaussianBlur(device: device, sigma: 7)
        nearKernel.edgeMode = .clamp; midKernel.edgeMode = .clamp; farKernel.edgeMode = .clamp
        do {
            let library = try device.makeLibrary(source: foldShader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch { fatalError("Unable to prepare Foldlight graphics: \(error)") }
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    func update(_ buffer: CVPixelBuffer) {
        if let retainedFrame, retainedFrame === buffer,
           let retainedTexture, let mapped = CVMetalTextureGetTexture(retainedTexture),
           texture === mapped { return }
        guard let cache else { return }
        var mapped: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
            .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &mapped)
        guard result == kCVReturnSuccess, let mapped, let texture = CVMetalTextureGetTexture(mapped) else { return }
        retainedFrame = buffer; retainedTexture = mapped; self.texture = texture
    }

    func encode(to output: MTLTexture, command: MTLCommandBuffer) {
        guard let texture else { return }
        let blurWidth = max(1, (texture.width + 1) / 2)
        let blurHeight = max(1, (texture.height + 1) / 2)
        if nearTexture?.width != blurWidth || nearTexture?.height != blurHeight {
            let scale = Float(blurWidth) / 1280
            nearKernel = MPSImageGaussianBlur(device: device, sigma: 2.2 * scale)
            midKernel = MPSImageGaussianBlur(device: device, sigma: 6.5 * scale)
            farKernel = MPSImageGaussianBlur(device: device, sigma: 14 * scale)
            nearKernel.edgeMode = .clamp; midKernel.edgeMode = .clamp; farKernel.edgeMode = .clamp
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: blurWidth, height: blurHeight, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
            reducedTexture = device.makeTexture(descriptor: descriptor)
            nearTexture = device.makeTexture(descriptor: descriptor)
            midTexture = device.makeTexture(descriptor: descriptor)
            farTexture = device.makeTexture(descriptor: descriptor)
            blurDirty = true
        }
        let useBlur = progress > 0.0001 && softness > 0
        if useBlur, blurDirty, let reducedTexture, let nearTexture, let midTexture, let farTexture {
            // Only the blur pyramid uses half resolution; the sharp desktop stays native Retina.
            downsample.encode(commandBuffer: command, sourceTexture: texture, destinationTexture: reducedTexture)
            nearKernel.encode(commandBuffer: command, sourceTexture: reducedTexture, destinationTexture: nearTexture)
            midKernel.encode(commandBuffer: command, sourceTexture: reducedTexture, destinationTexture: midTexture)
            farKernel.encode(commandBuffer: command, sourceTexture: reducedTexture, destinationTexture: farTexture)
            blurDirty = false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        var params = FoldParams(progress: progress, softness: softness,
            texel: SIMD2(1 / Float(texture.width), 1 / Float(texture.height)),
            viewport: SIMD2(Float(output.width), Float(output.height)), motion: motion)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(useBlur ? nearTexture ?? texture : texture, index: 1)
        encoder.setFragmentTexture(useBlur ? midTexture ?? texture : texture, index: 2)
        encoder.setFragmentTexture(useBlur ? farTexture ?? texture : texture, index: 3)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FoldParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func draw(in view: MTKView) {
        guard texture != nil, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else {
            inFlight.signal(); return
        }
        // Keep the pixel buffer alive until the GPU finishes this frame.
        let buffer = retainedFrame; let mapped = retainedTexture
        encode(to: drawable.texture, command: command)
        let limiter = inFlight
        command.addCompletedHandler { _ in
            withExtendedLifetime((buffer, mapped)) {}
            limiter.signal()
        }
        command.present(drawable); command.commit()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(screen: NSScreen, renderer: FoldRenderer) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        backgroundColor = .black; isOpaque = true; ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        title = "Foldlight Animation"
        let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: renderer.device)
        view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = true
        if let layer = view.layer as? CAMetalLayer { layer.displaySyncEnabled = true }
        view.isPaused = true; view.enableSetNeedsDisplay = false; view.delegate = renderer
        contentView = view
    }
    func registerForCapture() -> CGWindowID {
        // Give WindowServer a stable window ID before building the exclusion filter.
        // A barely visible prime also works when macOS omits fully transparent windows.
        if !isVisible { alphaValue = 0.001; orderFrontRegardless() }
        return windowNumber > 0 ? CGWindowID(windowNumber) : 0
    }
    func reveal() { alphaValue = 1; if !isVisible { orderFrontRegardless() } }
    func redraw() { (contentView as? MTKView)?.draw() }
}
