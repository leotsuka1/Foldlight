import AppKit
import MetalKit
import MetalPerformanceShaders
import CoreVideo

let foldShader = """
#include <metal_stdlib>
using namespace metal;
struct Vertex { float4 position [[position]]; float2 uv; };
struct Params { float progress; float softness; float2 texel; float2 viewport; float2 padding; };
vertex Vertex foldVertex(uint i [[vertex_id]]) {
    const float2 p[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    Vertex v; v.position=float4(p[i],0,1); v.uv=float2((p[i].x+1)*.5, (1-p[i].y)*.5); return v;
}
fragment float4 foldFragment(Vertex v [[stage_in]], texture2d<float> screen [[texture(0)]],
                              texture2d<float> nearBlur [[texture(1)]], texture2d<float> farBlur [[texture(2)]],
                              constant Params &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float amount=clamp(p.progress,0.0f,1.0f);
    // The open endpoint is an exact copy, including the outermost pixels.
    if(amount<.0001) return float4(screen.sample(s,v.uv).rgb,1);
    float theta=amount*1.535;
    float cosine=cos(theta), sine=sin(theta), perspective=.30*sine;
    float baseBow=.105*sine;
    float bowLimit=.8*cosine/(1+perspective);
    float bow=baseBow*rsqrt(1+pow(baseBow/max(bowLimit,.0001f),2.0));
    float height=1-v.uv.y;
    // Invert the projection of a gently curved sheet, anchored to the hinge.
    float a=cosine+bow-height*perspective;
    float discriminant=a*a-4*bow*height;
    float ambient=amount*amount*.012;
    float glow=exp(-pow((v.uv.x-.5)*1.4,2.0)-pow((v.uv.y-.90)*3.0,2.0));
    float3 background=float3(.42,.57,.62)*ambient*glow;
    if(discriminant<0 || a<=0) return float4(background,1);
    float q=2*height/(a+sqrt(max(discriminant,0.0f)));
    float scale=1+q*perspective;
    float2 uv=float2(.5+(v.uv.x-.5)*scale,1-q);
    // Rounded corners and analytic antialiasing stay consistent on Retina.
    float2 size=1/p.texel;
    float radius=18*(size.x/1280)*smoothstep(0.0,.22,amount);
    float2 position=(uv-.5)*size;
    float2 d=abs(position)-(size*.5-radius);
    float distance=length(max(d,0.0f))+min(max(d.x,d.y),0.0f)-radius;
    float aa=max(fwidth(distance),.5f);
    float coverage=1-smoothstep(-aa*.5,aa*.5,distance);
    if(coverage<=0) return float4(background,1);
    float depth=clamp(q,0.0f,1.0f);
    // Two optical blur scales preserve a crisp hinge and a soft receding edge.
    float focus=smoothstep(.10,.92,amount)*max(p.softness,0.0f)*(.10+.90*depth*depth);
    float3 sharp=screen.sample(s,uv).rgb;
    float3 soft=nearBlur.sample(s,uv).rgb;
    float3 diffuse=farBlur.sample(s,uv).rgb;
    float3 color=mix(sharp,soft,smoothstep(0.0,.38,focus));
    color=mix(color,diffuse,smoothstep(.25,1.0,focus)*.90);
    float hingeShade=exp(-depth*24)*sine*.15;
    float falloff=amount*amount*(.12+.16*depth);
    color*=1-falloff-hingeShade;
    // A broad, quiet reflection moves across the surface as the hinge turns.
    float band=exp(-pow((depth-(.86-.32*amount))/.28,2.0));
    color+=float3(.73,.83,.88)*band*sine*.045;
    float rim=exp(-abs(distance)/max(aa*1.2,1.0f))*sine*.16;
    color+=float3(.62,.80,.86)*rim;
    float settle=1-smoothstep(.94,1.0,amount);
    color*=settle;
    return float4(mix(background,color,coverage),1);
}
"""

struct FoldParams {
    var progress: Float
    var softness: Float
    var texel: SIMD2<Float>
    var viewport: SIMD2<Float>
    var padding = SIMD2<Float>(repeating: 0)
}

final class FoldRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var texture: MTLTexture? { didSet { blurDirty = true } }
    var progress: Float = 0
    var softness: Float = 1
    private var cache: CVMetalTextureCache?
    private var retainedFrame: CVPixelBuffer?
    private var retainedTexture: CVMetalTexture?
    private var nearKernel: MPSImageGaussianBlur
    private var farKernel: MPSImageGaussianBlur
    private var nearTexture: MTLTexture?
    private var farTexture: MTLTexture?
    private var blurDirty = true

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("This Mac does not support Metal.")
        }
        self.device = device; self.queue = queue
        nearKernel = MPSImageGaussianBlur(device: device, sigma: 1.6)
        farKernel = MPSImageGaussianBlur(device: device, sigma: 9)
        nearKernel.edgeMode = .clamp; farKernel.edgeMode = .clamp
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
        if nearTexture?.width != texture.width || nearTexture?.height != texture.height {
            let scale = Float(texture.width) / 1280
            nearKernel = MPSImageGaussianBlur(device: device, sigma: 1.6 * scale)
            farKernel = MPSImageGaussianBlur(device: device, sigma: 9 * scale)
            nearKernel.edgeMode = .clamp; farKernel.edgeMode = .clamp
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: texture.width, height: texture.height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
            nearTexture = device.makeTexture(descriptor: descriptor)
            farTexture = device.makeTexture(descriptor: descriptor)
            blurDirty = true
        }
        let useBlur = progress > 0.0001 && softness > 0
        if useBlur, blurDirty, let nearTexture, let farTexture {
            nearKernel.encode(commandBuffer: command, sourceTexture: texture, destinationTexture: nearTexture)
            farKernel.encode(commandBuffer: command, sourceTexture: texture, destinationTexture: farTexture)
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
            viewport: SIMD2(Float(output.width), Float(output.height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(useBlur ? nearTexture ?? texture : texture, index: 1)
        encoder.setFragmentTexture(useBlur ? farTexture ?? texture : texture, index: 2)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FoldParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func draw(in view: MTKView) {
        guard texture != nil, let drawable = view.currentDrawable, let command = queue.makeCommandBuffer() else { return }
        // Keep the pixel buffer alive until the GPU finishes this frame.
        let buffer = retainedFrame; let mapped = retainedTexture
        encode(to: drawable.texture, command: command)
        command.addCompletedHandler { _ in withExtendedLifetime((buffer, mapped)) {} }
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
