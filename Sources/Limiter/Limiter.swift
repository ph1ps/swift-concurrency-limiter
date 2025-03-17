import Synchronization
import OrderedCollections

@available(macOS 9999, *)
public final class AsyncLimiter: Sendable {
  
  typealias Continuation = UnsafeContinuation<Void, Error>
  
  struct SuspensionID: Hashable {
    let id: Int
  }
  
  struct State {
    
    enum EnterAction {
      case resume(Continuation)
      case cancel(Continuation)
      case escalate([UnsafeCurrentTask])
    }
    
    enum CancelAction {
      case cancel(Continuation)
    }
    
    enum LeaveAction {
      case resume(Continuation)
    }
    
    enum EscalationAction {
      case escalate([UnsafeCurrentTask])
    }
    
    enum Suspension {
      case active(UnsafeCurrentTask)
      case suspended(Continuation, UnsafeCurrentTask)
      case cancelled
    }
    
    let limit: Int
    var suspensions: OrderedDictionary<SuspensionID, Suspension> = [:]
    
    mutating func enter(id: SuspensionID, continuation: Continuation, task: UnsafeCurrentTask) -> EnterAction? {
      switch suspensions[id] {
      case .none:
        if suspensions.count >= limit {
          var tasks: [UnsafeCurrentTask] = []
          for (_, suspension) in suspensions {
            switch suspension {
            case .active(let task):
              tasks.append(task)
            case .suspended(_, let task):
              tasks.append(task)
            case .cancelled:
              break
            }
          }
          suspensions[id] = .suspended(continuation, task)
          if tasks.isEmpty {
            return nil
          } else {
            return .escalate(tasks)
          }
        } else {
          suspensions[id] = .active(task)
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
        return nil
      case .suspended(let continuation, _):
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
          continue
        case .suspended(let continuation, let task):
          suspensions[suspension.key] = .active(task)
          return .resume(continuation)
        }
      }
      return nil
    }
    
    func escalate(id: SuspensionID) -> EscalationAction? {
      switch suspensions[id] {
      case .none, .active, .cancelled:
        return nil
      case .suspended:
        break
      }
      var tasks: [UnsafeCurrentTask] = []
      for suspension in suspensions {
        if suspension.key == id {
          break
        }
        switch suspension.value {
        case .active(let task):
          tasks.append(task)
        case .suspended(_, let task):
          tasks.append(task)
        case .cancelled:
          break
        }
      }
      if tasks.isEmpty {
        return nil
      } else {
        return .escalate(tasks)
      }
    }
  }
  
  let counter: Atomic<Int>
  let state: Mutex<State>
  
  public init(limit: Int) {
    precondition(limit >= 1, "Needs at least one concurrent operation")
    counter = .init(0)
    state = .init(.init(limit: limit))
  }
  
  public func withControl<R, E>(
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws(E) -> sending R
  ) async throws -> R {
    
    let id = nextID()
    
    try await withTaskPriorityEscalationHandler(operation: {
      try await withTaskCancellationHandler(operation: {
        try await withUnsafeThrowingContinuation(isolation: isolation) { continuation in
          
          let action = state.withLock { state in
            withUnsafeCurrentTask { task in
              state.enter(id: id, continuation: continuation, task: task!)
            }
          }
          
          switch action {
          case .cancel(let continuation):
            continuation.resume(throwing: CancellationError())
          case .resume(let continuation):
            continuation.resume()
          case .escalate(let tasks):
            for task in tasks {
              UnsafeCurrentTask.escalatePriority(task, to: Task.currentPriority)
            }
          case .none:
            break
          }
        }
      }, onCancel: {
        let action = state.withLock { state in
          state.cancel(id: id)
        }
        
        switch action {
        case .cancel(let continuation):
          continuation.resume(throwing: CancellationError())
        case .none:
          break
        }
      }, isolation: isolation)
    }, onPriorityEscalated: { priority in
      let action = state.withLock { state in
        state.escalate(id: id)
      }
      
      switch action {
      case .escalate(let tasks):
        for task in tasks {
          UnsafeCurrentTask.escalatePriority(task, to: priority)
        }
      case .none:
        break
      }
    }, isolation: isolation)
    
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
