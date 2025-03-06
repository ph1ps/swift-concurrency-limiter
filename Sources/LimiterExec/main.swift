import Limiter

// This is required, because the default executor schedules the high prio task before the low prio.
@globalActor actor NaiveActor {
  final class NaiveExecutor: SerialExecutor {
    let queue = DispatchQueue(label: "random")
    func enqueue(_ job: consuming ExecutorJob) {
      let job = UnownedJob(job)
      let executor = asUnownedSerialExecutor()
      queue.async {
        job.runSynchronously(on: executor)
      }
    }
  }
  static let shared = NaiveActor()
  let executor = NaiveExecutor()
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }
}

@NaiveActor
func testEscalation() async throws {
  
  let limiter = AsyncLimiter(limit: 1)
  
  Task(priority: .low) { @NaiveActor in
    print("task1 before", Task.currentPriority)
    try await limiter.withControl {
      print("task1 inside", Task.currentPriority)
      try await Task.sleep(for: .seconds(1))
      print("task1 after", Task.currentPriority) // should be high
    }
  }
  
  Task(priority: .medium) { @NaiveActor in
    print("task2 before", Task.currentPriority)
    try await limiter.withControl {
      print("task2 inside", Task.currentPriority)
      try await Task.sleep(for: .seconds(1))
      print("task2 after", Task.currentPriority) // should be high
    }
  }
  
  Task(priority: .high) { @NaiveActor in
    print("task3 before", Task.currentPriority)
    try await limiter.withControl {
      print("task3 inside", Task.currentPriority)
      try await Task.sleep(for: .seconds(1))
      print("task3 after", Task.currentPriority)
    }
  }
}

Task {
  try await testEscalation()
}

import Foundation
RunLoop.main.run()
