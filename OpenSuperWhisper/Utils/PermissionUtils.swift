
    func checkAccessibilityPermissions() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
        return AXIsProcessTrustedWithOptions(options)
    }