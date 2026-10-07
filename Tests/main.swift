import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

var state = PhysicalFnState()
state.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: true, physical: true)
require(state.isDown, "Physical Apple Top Case Fn press must start the hold")
// Regression: Gemini clears the global Fn state while recording starts.
state.receive(device: 99, cookie: 296, page: 0xff, usage: 3, down: false, physical: false)
require(state.isDown, "A software-generated Fn-up must not release physical Fn")
state.receive(device: 1, cookie: 50, page: 7, usage: 4, down: false, physical: true)
require(state.isDown, "Unrelated physical keys must not release Fn")
state.receive(device: 2, cookie: 4, page: 0xff01, usage: 3, down: true, physical: true)
state.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: false, physical: true)
require(state.isDown, "A second keyboard's held Fn must remain active")
state.remove(device: 2)
require(!state.isDown, "Unplugging the remaining keyboard must release its Fn hold")
state.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: true, physical: true)
state.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: true, physical: true)
state.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: false, physical: true)
require(!state.isDown, "Repeated reports must not make a physical release stick")
state.receive(device: 1, cookie: 296, page: 0xff, usage: 3, down: true, physical: false)
require(!state.isDown, "A virtual keyboard must not start a physical hold")
state.receive(device: 1, cookie: 296, page: 0xff01, usage: 3, down: true, physical: true)
state.clear()
require(!state.isDown, "Stopping monitoring must clear all held keys")
print("PASS: physical Fn, synthetic release regression, unrelated keys, multiple keyboards, removal, duplicate reports, virtual keys, and cleanup.")
