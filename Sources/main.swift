import Cocoa
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var archive: URL?
    var inputs: [URL] = []
    var destination: URL?
    var result: URL?
    var job: ArchiveJob?
    var cancelled = false
    var compressing: Bool { mode.selectedSegment == 1 }
    let mode = NSSegmentedControl(labels: ["解压", "压缩"], trackingMode: .selectOne, target: nil, action: nil)
    let fileLabel = NSTextField(wrappingLabelWithString: "尚未选择压缩包")
    let folderLabel = NSTextField(wrappingLabelWithString: "尚未选择保存位置")
    let status = NSTextField(wrappingLabelWithString: "请选择压缩包与保存位置。")
    let note = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let chooseFile = NSButton(title: "选择压缩包…", target: nil, action: nil)
    let chooseFolder = NSButton(title: "选择保存位置…", target: nil, action: nil)
    let startButton = NSButton(title: "开始解压", target: nil, action: nil)
    let cancel = NSButton(title: "取消", target: nil, action: nil)
    let open = NSButton(title: "在 Finder 中查看", target: nil, action: nil)
    let format = NSPopUpButton(frame: .zero, pullsDown: false)
    let name = NSTextField(string: "压缩文件")
    var compressionOptions: NSStackView!
    var selectedFormat: CompressionFormat { CompressionFormat.allCases[max(0, format.indexOfSelectedItem)] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item); item.submenu = NSMenu()
        item.submenu?.addItem(withTitle: "关于 压缩助手", action: #selector(about), keyEquivalent: "")
        item.submenu?.addItem(.separator())
        item.submenu?.addItem(withTitle: "退出 压缩助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "压缩助手"
        window.minSize = NSSize(width: 640, height: 600)
        window.delegate = self; window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "压缩助手")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "轻松打包文件，也让压缩包回到文件夹。")
        subtitle.textColor = .secondaryLabelColor
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(changeMode)
        mode.segmentStyle = .rounded
        for label in [fileLabel, folderLabel] {
            label.textColor = .secondaryLabelColor; label.maximumNumberOfLines = 3
            label.lineBreakMode = .byTruncatingMiddle
        }
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        for (button, action) in [(chooseFile, #selector(selectFile)), (chooseFolder, #selector(selectFolder)), (startButton, #selector(start)), (cancel, #selector(stop)), (open, #selector(showOutput))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        startButton.keyEquivalent = "\r"
        cancel.isHidden = true; open.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        format.addItems(withTitles: CompressionFormat.allCases.map { $0.title })
        name.placeholderString = "输入压缩包名称，无需扩展名"
        let formatRow = NSStackView(views: [NSTextField(labelWithString: "压缩格式"), format])
        formatRow.orientation = .horizontal; formatRow.spacing = 14
        let nameRow = NSStackView(views: [NSTextField(labelWithString: "文件名称"), name])
        nameRow.orientation = .horizontal; nameRow.spacing = 14
        compressionOptions = NSStackView(views: [formatRow, nameRow])
        compressionOptions.orientation = .vertical; compressionOptions.alignment = .leading; compressionOptions.spacing = 12
        let actions = NSStackView(views: [startButton, cancel, open, spinner])
        actions.orientation = .horizontal; actions.spacing = 10
        let stack = NSStackView(views: [title, subtitle, mode, chooseFile, fileLabel, compressionOptions, chooseFolder, folderLabel, actions, status, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            name.widthAnchor.constraint(equalToConstant: 340)
        ])
        updateMode()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc func changeMode() { guard job == nil else { return }; result = nil; open.isHidden = true; updateMode() }
    func updateMode() {
        compressionOptions.isHidden = !compressing
        chooseFile.title = compressing ? "选择文件或文件夹…" : "选择压缩包…"
        startButton.title = compressing ? "开始压缩" : "开始解压"
        if compressing {
            fileLabel.stringValue = inputs.isEmpty ? "尚未选择文件或文件夹（支持多选）" : selectionDescription()
            note.stringValue = "支持 ZIP、7Z、TAR、TAR.GZ、TAR.BZ2、TAR.XZ。保留目录结构，自动避开同名压缩包。TAR 仅打包；此版本不创建 RAR 或加密压缩包。"
        } else {
            fileLabel.stringValue = archive?.path ?? "尚未选择压缩包"
            note.stringValue = "支持 RAR / RAR5、ZIP、7Z、TAR、TAR.GZ / TGZ、TAR.BZ2、TAR.XZ，以及单文件 GZ / BZ2。解压到独立文件夹；加密或分卷压缩包可能不支持。"
        }
        status.stringValue = compressing ? "请选择要压缩的项目与保存位置。" : "请选择压缩包与保存位置。"
        refresh()
    }
    func selectionDescription() -> String {
        if inputs.count == 1 { return inputs[0].path }
        return "已选择 \(inputs.count) 项：" + inputs.map { $0.lastPathComponent }.joined(separator: "、")
    }
    @objc func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = compressing; panel.canChooseFiles = true; panel.allowsMultipleSelection = compressing
        if !compressing {
            // Let users select archives with unusual or missing extensions too.
            panel.message = "支持 RAR、ZIP、7Z、TAR 等常见压缩包。"
        } else { panel.message = "可同时选择多个文件和文件夹。" }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            if self.compressing {
                self.inputs = panel.urls
                self.fileLabel.stringValue = self.selectionDescription()
                self.fileLabel.toolTip = self.inputs.map { $0.path }.joined(separator: "\n")
                self.name.stringValue = self.inputs.count == 1 ? self.inputs[0].deletingPathExtension().lastPathComponent : "归档文件"
            } else if let url = panel.url {
                self.archive = url; self.fileLabel.stringValue = url.path; self.fileLabel.toolTip = url.path
            }
            self.result = nil; self.open.isHidden = true; self.refresh()
        }
    }
    @objc func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "保存到此位置"
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                self.destination = url; self.folderLabel.stringValue = url.path
                self.folderLabel.toolTip = url.path; self.refresh()
            }
        }
    }
    func refresh() { startButton.isEnabled = (compressing ? !inputs.isEmpty : archive != nil) && destination != nil && job == nil }
    func busy(_ active: Bool) {
        chooseFile.isEnabled = !active; chooseFolder.isEnabled = !active
        mode.isEnabled = !active; format.isEnabled = !active; name.isEnabled = !active
        cancel.isHidden = !active; cancel.isEnabled = active
        if active { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refresh()
    }
    @objc func start() {
        guard let destination, job == nil else { return }
        let operation = compressing ? "压缩" : "解压"
        do {
            let task: ArchiveJob
            if compressing {
                task = try ArchiveJob(inputs: inputs, destination: destination, name: name.stringValue, format: selectedFormat)
            } else {
                guard let archive else { return }
                task = try ArchiveJob(archive: archive, destination: destination)
            }
            job = task; cancelled = false; result = nil; open.isHidden = true; busy(true)
            status.stringValue = "正在\(operation)，请稍候…"
            DispatchQueue.global(qos: .userInitiated).async {
                task.process.waitUntilExit()
                DispatchQueue.main.async {
                    defer { self.job = nil; self.busy(false) }
                    if self.cancelled {
                        task.cleanup(); self.status.stringValue = "已取消\(operation)。"; return
                    }
                    do {
                        let output = try task.finish()
                        self.result = output; self.open.isHidden = false
                        self.status.stringValue = "\(operation)完成：\(output.lastPathComponent)"
                    } catch {
                        task.cleanup()
                        self.status.stringValue = "\(operation)失败。"
                        self.showError(title: "\(operation)失败", message: error.localizedDescription)
                    }
                }
            }
        } catch {
            status.stringValue = "无法开始\(operation)。"
            showError(title: "无法开始\(operation)", message: error.localizedDescription)
        }
    }
    func showError(title: String, message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    @objc func stop() {
        guard let job else { return }
        cancelled = true; cancel.isEnabled = false; status.stringValue = "正在取消，请稍候…"
        if job.process.isRunning { job.process.terminate() }
    }
    @objc func showOutput() {
        if let result { NSWorkspace.shared.activateFileViewerSelecting([result]) }
    }
    @objc func about() {
        let alert = NSAlert(); alert.messageText = "压缩助手 2.0"
        alert.informativeText = "原生 Mac 文件压缩与解压工具。\n选择项目和保存位置即可使用，无需安装额外工具。\n\n支持格式受当前 macOS 系统归档工具能力限制。"
        alert.beginSheetModal(for: window)
    }
    func allowClose() -> Bool {
        guard job != nil else { return true }
        status.stringValue = "任务进行中。请先点击“取消”，等待任务结束后关闭。"
        NSSound.beep(); return false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { allowClose() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let args = CommandLine.arguments
if args.count > 1 && (args[1] == "--extract" || args[1] == "--compress") {
    var task: ArchiveJob?
    do {
        if args[1] == "--extract", args.count == 4 {
            task = try ArchiveJob(archive: URL(fileURLWithPath: args[2]), destination: URL(fileURLWithPath: args[3]))
        } else if args[1] == "--compress", args.count >= 6, let format = CompressionFormat(rawValue: args[2]) {
            task = try ArchiveJob(inputs: args.dropFirst(5).map { URL(fileURLWithPath: $0) }, destination: URL(fileURLWithPath: args[3]), name: args[4], format: format)
        } else { throw ArchiveError.message("Usage: --extract ARCHIVE DEST | --compress FORMAT DEST NAME INPUT...") }
        task!.process.waitUntilExit()
        print(try task!.finish().path)
    } catch { task?.cleanup(); fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
