import SwiftUI
import AppKit
import SwiftTerm

/// ProcessManager'ın sahip olduğu kalıcı terminal view'ını SwiftUI içinde
/// barındırır. Container BİR KEZ mount edilir; sekme/anahtar değişince gömülü
/// terminal takas edilir — böylece SwiftTerm'in scroll konumu ve buffer'ı
/// yaşamaya devam eder (representable'ı yeniden yaratmak alta sıfırlıyordu).
struct TerminalHostView: NSViewRepresentable {
    let key: String
    let manager: ProcessManager

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.autoresizingMask = [.width, .height]
        container.attach(manager.terminalView(forKey: key))
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.attach(manager.terminalView(forKey: key))
    }
}

/// Aynı anda tek terminal barındırır. `attach` idempotenttir: SwiftUI'nin sık
/// updateNSView çağrıları view ağacını hırpalamaz.
final class TerminalContainerView: NSView {
    private weak var currentTerminal: LocalProcessTerminalView?
    /// Canlı pencere sürüklemede SwiftTerm'in ağır resize hattını (cols/rows
    /// hesabı + TIOCSWINSZ) her mouse-move'da koşturmamak için debounce.
    private var resizeDebounce: DispatchWorkItem?

    func attach(_ tv: LocalProcessTerminalView) {
        if currentTerminal === tv { return }
        // Önceki terminali ve yeni terminalin eski parent'ını sök —
        // aynı NSView iki hiyerarşide olamaz.
        currentTerminal?.removeFromSuperview()
        tv.removeFromSuperview()
        tv.frame = bounds
        tv.autoresizingMask = [.width, .height]
        addSubview(tv)
        currentTerminal = tv

        // Çift refresh: t=0 boyut+odak+ilk çizim, t=350ms Cocoa layout
        // turu bittikten sonra ikinci çizim — attach sonrası bayat/boş
        // canvas'ı deterministik olarak toparlar.
        DispatchQueue.main.async { [weak tv, weak self] in
            guard let view = tv, let self = self, let window = view.window else { return }
            let target = self.bounds.size
            if target.width > 0 && target.height > 0 {
                view.setFrameSize(target)
            }
            window.makeFirstResponder(view)
            view.needsDisplay = true
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak tv] in
            guard let view = tv, view.window != nil else { return }
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let tv = currentTerminal, newSize.width > 0, newSize.height > 0 else { return }

        // Sürükleme boyunca canvas gerçek zamanlı takip etsin.
        tv.setFrameSize(newSize)

        // Temiz repaint sürüklemenin bitişine (son tik + 80ms) ertelenir.
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak tv] in
            guard let view = tv, view.window != nil else { return }
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
