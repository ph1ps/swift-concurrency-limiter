import Clocks
import Foundation
import Limiter
import Synchronization
import Testing

// This is required, because the default executor schedules the high prio task before the low prio.
final class NaiveExecutor: TaskExecutor {
  
  let queue: DispatchQueue
  
  init(queue: DispatchQueue) {
    self.queue = queue
  }
  
  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedTaskExecutor()
    queue.async {
      job.runSynchronously(on: executor)
    }
  }
}

struct CustomError: Error { }

func never() async throws {
  let never = AsyncStream<Void> { _ in }
  for await _ in never { }
  throw CancellationError()
}

@available(macOS 9999, *)
@Test
func testAsyncMutex() async throws {
  
  @globalActor actor CustomActor { static let shared = CustomActor() }
  
  try await withThrowingTaskGroup(of: Int.self) { taskGroup in
    
    let clock = TestClock()
    let limiter = AsyncLimiter(limit: 1)
    
    let now = clock.now
    let firstDeadline = now.advanced(by: .seconds(2))
    let secondDeadline = now.advanced(by: .seconds(1))
    
    taskGroup.addTask { @Sendable @CustomActor in
      return try await limiter.withControl {
        try await clock.sleep(until: firstDeadline)
        return 1
      }
    }
    
    taskGroup.addTask { @Sendable @CustomActor in
      return try await limiter.withControl {
        try await clock.sleep(until: secondDeadline)
        return 2
      }
    }
    
    await clock.advance(by: .seconds(2))
    let first = try await taskGroup.next()!
    let second = try await taskGroup.next()!
    
    #expect(first == 1)
    #expect(second == 2)
  }
}

@available(macOS 9999, *)
@Test
func testImmediateCancel() async {
  
  let limiter = AsyncLimiter(limit: 1)
  let task = Task {
    try await limiter.withControl {
      do {
        try await never()
      } catch {
        throw CustomError()
      }
    }
  }
  
  task.cancel()
  
  await #expect {
    try await task.value
  } throws: { error in
    // NB: If cancellation happened when job was already scheduled, the operation has to handle cancellation.
    // In this case, this will result in CustomError.
    error is CancellationError || error is CustomError
  }
}

@available(macOS 9999, *)
@Test
func testDelayedCancel() async {
  
  let executor = NaiveExecutor(queue: .init(label: #function))
  await withTaskExecutorPreference(executor) {
    let limiter = AsyncLimiter(limit: 1)
    
    let task1 = Task(executorPreference: executor) {
      try await limiter.withControl {
        try await never()
      }
    }
    
    let task2 = Task(executorPreference: executor) {
      try await limiter.withControl {
        do {
          try await never()
        } catch {
          throw CustomError()
        }
      }
    }
    
    await Task.yield()
    task2.cancel()
    task1.cancel()
    
    await #expect(throws: CancellationError.self) {
      try await task2.value
    }
  }
}

@available(macOS 9999, *)
@Test
func testEscalation() async throws {
  
  struct Priorities {
    var task1Before: TaskPriority?
    var task1Inside: TaskPriority?
    var task1After: TaskPriority?
    var task2Before: TaskPriority?
    var task2Inside: TaskPriority?
    var task2After: TaskPriority?
    var task3Before: TaskPriority?
    var task3Inside: TaskPriority?
    var task3After: TaskPriority?
  }
  
  let executor = NaiveExecutor(queue: .init(label: #function))
  let clock = TestClock()
  let deadline = clock.now.advanced(by: .seconds(1))
  let limiter = AsyncLimiter(limit: 1)
  let priorities = Mutex(Priorities())
  let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
  
  Task(executorPreference: executor, priority: .low) { @Sendable in
    priorities.withLock { $0.task1Before = Task.currentPriority }
    try await limiter.withControl {
      priorities.withLock { $0.task1Inside = Task.currentPriority }
      try await clock.sleep(until: deadline)
      priorities.withLock { $0.task1After = Task.currentPriority }
    }
    continuation.yield()
  }
  
  Task(executorPreference: executor, priority: .medium) { @Sendable in
    priorities.withLock { $0.task2Before = Task.currentPriority }
    try await limiter.withControl {
      priorities.withLock { $0.task2Inside = Task.currentPriority }
      try await clock.sleep(until: deadline)
      priorities.withLock { $0.task2After = Task.currentPriority }
    }
    continuation.yield()
  }
  
  Task(executorPreference: executor, priority: .high) { @Sendable in
    priorities.withLock { $0.task3Before = Task.currentPriority }
    try await limiter.withControl {
      priorities.withLock { $0.task3Inside = Task.currentPriority }
      try await clock.sleep(until: deadline)
      priorities.withLock { $0.task3After = Task.currentPriority }
    }
    continuation.yield()
  }
  
  await clock.advance(by: .seconds(1))
  var iterator = stream.makeAsyncIterator()
  await iterator.next()!
  await iterator.next()!
  await iterator.next()!
  continuation.finish()
  
  priorities.withLock { priorities in
    #expect(priorities.task1Before == .low)
    #expect(priorities.task1Inside == .low)
    #expect(priorities.task1After == .high)
    #expect(priorities.task2Before == .medium)
    #expect(priorities.task2Inside == .high)
    #expect(priorities.task2After == .high)
    #expect(priorities.task3Before == .high)
    #expect(priorities.task3Inside == .high)
    #expect(priorities.task3After == .high)
  }
}
