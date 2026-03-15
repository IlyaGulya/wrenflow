import Foundation

let notifications: [String: String] = [
    "start": "me.gulya.wrenflow.start-recording",
    "stop": "me.gulya.wrenflow.stop-recording",
    "toggle": "me.gulya.wrenflow.toggle-recording",
]

func printUsage() {
    let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "wrenflow"
    fputs("""
    Usage: \(name) <command>

    Commands:
      start    Start recording
      stop     Stop recording and transcribe
      toggle   Toggle recording on/off
      status   Print current state (recording/idle)

    """, stderr)
}

func handleStatus() {
    let center = DistributedNotificationCenter.default()
    var receivedResponse = false

    let observer = center.addObserver(
        forName: .init("me.gulya.wrenflow.status-response"),
        object: nil,
        queue: nil
    ) { notification in
        let state = notification.object as? String ?? "unknown"
        print(state)
        receivedResponse = true
        CFRunLoopStop(CFRunLoopGetMain())
    }

    center.postNotificationName(
        .init("me.gulya.wrenflow.status-request"),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )

    CFRunLoopRunInMode(.defaultMode, 2.0, false)
    center.removeObserver(observer)

    if !receivedResponse {
        fputs("No response from Wrenflow (is it running?)\n", stderr)
        exit(1)
    }
}

guard CommandLine.arguments.count == 2 else {
    printUsage()
    exit(1)
}

let command = CommandLine.arguments[1]

if command == "status" {
    handleStatus()
} else if let notificationName = notifications[command] {
    let center = DistributedNotificationCenter.default()
    var received = false

    // Subscribe to ack BEFORE sending the command to avoid race
    let observer = center.addObserver(
        forName: .init("me.gulya.wrenflow.ack"),
        object: nil,
        queue: nil
    ) { notification in
        let payload = notification.object as? String ?? ""
        if payload.hasPrefix("\(command):") {
            let state = String(payload.dropFirst(command.count + 1))
            print("\(command): ok (state: \(state))")
            received = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    center.postNotificationName(
        .init(notificationName),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )

    CFRunLoopRunInMode(.defaultMode, 2.0, false)
    center.removeObserver(observer)

    if !received {
        fputs("No response from Wrenflow (is it running?)\n", stderr)
        exit(1)
    }
} else {
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
}
