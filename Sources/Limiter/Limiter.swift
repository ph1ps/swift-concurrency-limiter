import Synchronization
import OrderedCollections

func withTaskCancellationHandler<T>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async throws -> T,
  onCancel handler: @Sendable () -> Void
) async rethrows -> T {
  try await withTaskCancellationHandler(operation: operation, onCancel: handler, isolation: isolation)
}

public final class AsyncLimiter: Sendable {
  
  typealias Continuation = UnsafeContinuation<Void, Error>
  
  struct SuspensionID: Hashable {
    let id: Int
  }
  
  struct State {
    
    enum EnterAction {
      case resume(Continuation)
      case cancel(Continuation)
    }
    
    enum CancelAction {
      case cancel(Continuation)
    }
    
    enum LeaveAction {
      case resume(Continuation)
    }
    
    enum Suspension {
      case active
      case suspended(Continuation)
      case cancelled
    }
    
    let limit: Int
    var suspensions: OrderedDictionary<SuspensionID, Suspension> = [:]
    
    mutating func enter(id: SuspensionID, continuation: Continuation) -> EnterAction? {
      switch suspensions[id] {
      case .none:
        if suspensions.count >= limit {
          suspensions[id] = .suspended(continuation)
          return nil
        } else {
          suspensions[id] = .active
          return .resume(continuation)
        }
      case .active, .suspended:
        preconditionFailure("Invalid state")
      case .cancelled:
        suspensions[id] = nil
        return .cancel(continuation)
      }
    }
    
    mutating func cancel(id: SuspensionID) -> CancelAction? {
      switch suspensions[id] {
      case .none:
        suspensions[id] = .cancelled
        return nil
      case .active:
        return nil // TODO: not yet covered by unit tests
      case .suspended(let continuation):
        suspensions[id] = nil
        return .cancel(continuation)
      case .cancelled:
        preconditionFailure("Invalid state")
      }
    }
    
    mutating func leave(id: SuspensionID) -> LeaveAction? {
      switch suspensions[id] {
      case .none, .suspended, .cancelled:
        preconditionFailure("Invalid state")
      case .active:
        suspensions[id] = nil
      }
      for suspension in suspensions {
        switch suspension.value {
        case .active, .cancelled:
          continue // TODO: not yet covered by unit tests
        case .suspended(let continuation):
          suspensions[suspension.key] = .active
          return .resume(continuation)
        }
      }
      return nil
    }
  }
  
  let counter: Atomic<Int>
  let state: Mutex<State>
  
  // TODO: For now, inOrder is always true
  public init(limit: Int/*, inOrder: Bool*/) {
    precondition(limit >= 1, "Needs at least one concurrent operation")
    counter = .init(0)
    state = .init(.init(limit: limit))
  }
  
  public func withControl<R, E>(
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws(E) -> sending R
  ) async throws -> R {
    
    let id = nextID()
    
    try await withTaskCancellationHandler(isolation: isolation) {
      try await withUnsafeThrowingContinuation(isolation: isolation) { continuation in
        
        let action = state.withLock { state in
          state.enter(id: id, continuation: continuation)
        }
        
        switch action {
        case .cancel(let continuation):
          continuation.resume(throwing: CancellationError())
        case .resume(let continuation):
          continuation.resume()
        case .none:
          break
        }
      }
    } onCancel: {
      
      let action = state.withLock { state in
        state.cancel(id: id)
      }
      
      switch action {
      case .cancel(let continuation):
        continuation.resume(throwing: CancellationError())
      case .none:
        break
      }
    }
    
    defer {
      
      let action = state.withLock { state in
        state.leave(id: id)
      }
      
      switch action {
      case .resume(let continuation):
        continuation.resume()
      case .none:
        break
      }
    }
    
    return try await operation()
  }
  
  func nextID() -> SuspensionID {
    return SuspensionID(id: counter.wrappingAdd(1, ordering: .relaxed).newValue)
  }
}
