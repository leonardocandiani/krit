// The webcam during recording now shows as a floating circular bubble on screen
// (see CameraBubbleWindow), left IN the SCStream capture so it is recorded in
// place. That replaced the previous off-screen PiP path, which blended the
// webcam into every captured frame via a CIContext composite (WebcamFrameBox,
// WebcamCaptureDelegate, WebcamCompositor). Those types were removed with the
// composite path: the bubble needs no per-frame compositing and keeps the
// zero-copy screen-frame append.
