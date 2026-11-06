import MetalKit
import OnAirCore
import UIKit

/// Hosts the ImGui interface: one Metal layer, driven frame by frame, with touches and the keyboard passed to C++.
final class OnAirMetalView: MTKView, MTKViewDelegate, UIKeyInput {
    private var started = false

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 60
        isMultipleTouchEnabled = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        onair_resize(Int32(bounds.width), Int32(bounds.height), Float(contentScaleFactor))
        if !started {
            started = onair_start(Unmanaged.passUnretained(layer).toOpaque(), nil)
        }
    }

    // MARK: Frames

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard started else { return }
        onair_frame()
        let wantsKeyboard = onair_wants_keyboard()
        if wantsKeyboard != isFirstResponder {
            keyboardType = onair_keyboard_kind() == 1 ? .decimalPad : .default
            _ = wantsKeyboard ? becomeFirstResponder() : resignFirstResponder()
        }
    }

    // MARK: Touch

    private func send(_ touches: Set<UITouch>, phase: Int32) {
        for touch in touches {
            let point = touch.location(in: self)
            onair_touch(Int32(truncatingIfNeeded: ObjectIdentifier(touch).hashValue), Float(point.x), Float(point.y), phase)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 0) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 1) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 2) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 3) }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var keyboardType: UIKeyboardType = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { onair_key_enter() } else { onair_text(text) }
    }

    func deleteBackward() { onair_key_backspace() }
}
