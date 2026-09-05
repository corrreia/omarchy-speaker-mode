import QtQuick
import Quickshell.Io

// Every child process the widget starts goes through here. The helper is ours,
// but it waits on BlueZ, obexd and PipeWire, any of which can stall, and a
// stalled child would otherwise sit in the process list for good. So a run
// gets a deadline — a TERM at the deadline, a KILL a few seconds later if it
// is still there — and its output a ceiling, past which it is dropped rather
// than parsed. Collected output arrives through `collected`; anything the
// child said on stderr lands in `errorText`.
Process {
  id: proc

  property int deadlineMs: 20000
  property int maxOutputChars: 65536
  property bool timedOut: false
  property string errorText: ""

  signal collected(string text)

  readonly property Timer deadline: Timer {
    interval: proc.deadlineMs
    repeat: false
    onTriggered: {
      if (!proc.running) return
      proc.timedOut = true
      proc.signal(15)
      proc.grace.restart()
    }
  }

  readonly property Timer grace: Timer {
    interval: 3000
    repeat: false
    onTriggered: if (proc.running) proc.signal(9)
  }

  function bounded(text) {
    var value = String(text || "")
    if (timedOut || value.length > maxOutputChars) return ""
    return value
  }

  onStarted: {
    timedOut = false
    errorText = ""
    deadline.restart()
  }

  onExited: {
    deadline.stop()
    grace.stop()
    if (timedOut && errorText === "") errorText = "Speaker mode command timed out"
  }

  stdout: StdioCollector {
    waitForEnd: true
    onStreamFinished: proc.collected(proc.bounded(text))
  }

  stderr: StdioCollector {
    waitForEnd: true
    onStreamFinished: {
      var message = proc.bounded(text).trim()
      if (message !== "") proc.errorText = message.slice(0, 500)
    }
  }
}
