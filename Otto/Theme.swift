import SwiftUI

/// Otto's contact photo everywhere he appears: the same 3D orange face as the conversations list and
/// the thread's header. Typing shows as working, sleeping as asleep; the face draws its own blink and Zs,
/// and holds still under Reduce Motion.
struct OttoAvatar: View {
    var size: CGFloat = 44
    var thinking = false
    var asleep = false

    var body: some View {
        // Small faces play cached frames; large ones render live, for the eye transitions.
        FaceView(look: .otto.with(asleep ? .asleep : thinking ? .working : .rest), size: size, live: size > 32)
            .frame(width: size, height: size)
    }
}
