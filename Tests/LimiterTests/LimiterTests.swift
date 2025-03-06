import Clocks
import Limiter
import Synchronization
import Testing

@Test
func testLimit1() async throws {
  
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

@globalActor actor ImmediateCancelActor {
  static let shared = ImmediateCancelActor()
}

@Test
@ImmediateCancelActor
func testImmediateCancel() async {
  
  struct CustomCancellationError: Error { }
  
  let clock = TestClock()
  let limiter = AsyncLimiter(limit: 1)
  
  let deadline = clock.now.advanced(by: .seconds(1))
  
  let task1 = Task { @ImmediateCancelActor in
    try await limiter.withControl {
      do {
        try await clock.sleep(until: deadline)
      } catch {
        throw CustomCancellationError()
      }
    }
  }
  
  let task2 = Task { @ImmediateCancelActor in
    try await limiter.withControl {
      do {
        try await clock.sleep(until: deadline)
      } catch {
        throw CustomCancellationError()
      }
    }
  }
  
  task2.cancel()
  
  await clock.advance(by: .seconds(1))
  await #expect(throws: CancellationError.self) {
    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      taskGroup.addTask { try await task1.value }
      taskGroup.addTask { try await task2.value }
      try await taskGroup.waitForAll()
    }
  }
}

@globalActor actor DelayedCancelActor {
  static let shared = ImmediateCancelActor()
}

@Test
@DelayedCancelActor
func testDelayedCancel() async {
  
  @globalActor actor Custom { static let shared = Custom() }
  struct CustomCancellationError: Error { }
  
  let clock = TestClock()
  let limiter = AsyncLimiter(limit: 1)
  
  let deadline = clock.now.advanced(by: .seconds(2))
  
  let task1 = Task { @DelayedCancelActor in
    try await limiter.withControl {
      do {
        try await clock.sleep(until: deadline)
      } catch {
        throw CustomCancellationError()
      }
    }
  }
  
  let task2 = Task { @DelayedCancelActor in
    try await limiter.withControl {
      do {
        try await clock.sleep(until: deadline)
      } catch {
        throw CustomCancellationError()
      }
    }
  }
  
  await clock.advance(by: .seconds(1))
  task2.cancel()
  await clock.advance(by: .seconds(1))
  
  await #expect(throws: CancellationError.self) {
    try await withThrowingTaskGroup(of: Void.self) { taskGroup in
      taskGroup.addTask { try await task1.value }
      taskGroup.addTask { try await task2.value }
      try await taskGroup.waitForAll()
    }
  }
}
