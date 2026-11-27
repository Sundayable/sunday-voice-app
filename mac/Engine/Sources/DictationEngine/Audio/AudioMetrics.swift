import Foundation

/// Numeric diagnostics only; never retain audio or dictated text.
final class AudioMetrics {
    private let lock=NSLock()
    private var frames=0
    private var peak=0.0
    private var energy=0.0
    func reset() {lock.lock();defer{lock.unlock()};frames=0;peak=0;energy=0}
    func add(_ samples:UnsafePointer<Int16>,count:Int) {
        var p=0.0,e=0.0
        for i in 0..<count {let value=Double(samples[i])/32768;p=max(p,abs(value));e+=value*value}
        lock.lock();defer{lock.unlock()};frames+=count;peak=max(peak,p);energy+=e
    }
    func snapshot()->[String:Any] {
        lock.lock();defer{lock.unlock()}
        return ["audio_frames":frames,"audio_seconds":Double(frames)/24000,"peak":peak,"rms":frames>0 ? sqrt(energy/Double(frames)):0]
    }
}
