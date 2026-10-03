# Changelog

## 1.1.1

- Fix recursive desktop capture when the settings window is closed.
- Register and explicitly exclude the animation window before capture starts.
- Refuse capture if the required window exclusion cannot be confirmed.
- Ignore stale capture callbacks after streams stop or restart.
- Add a live regression check for capture with settings closed and after restart.

## 1.1.0

- Add curved surface shading, smooth blur, rounded edges, reflections, and hinge shadows.
- Smooth lid tracking without bounce and support rendering up to 120 fps.
- Preserve native Retina capture resolution.
- Improve the eight-second sample preview.

## 1.0.0

- Initial native Mac menu bar app with lid-reactive desktop folding and sample preview.
