// because of -parse-stdlib to get compiler builtins
import Swift
import _Concurrency

@_silgen_name("swift_task_addPriorityEscalationHandler")
func _taskAddPriorityEscalationHandler(handler: (UInt8) -> Void) -> UnsafeRawPointer

@_silgen_name("swift_task_removePriorityEscalationHandler")
func _taskRemovePriorityEscalationHandler(record: UnsafeRawPointer)

@_silgen_name("swift_task_escalate")
@discardableResult
func _taskEscalate(_ task: Builtin.NativeObject, newPriority: UInt8) -> UInt8

func withTaskPriorityEscalationHandler<T, E>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async throws(E) -> sending T,
  onPriorityEscalated handler: @Sendable (TaskPriority) -> Void
) async throws(E) -> T {
  // NOTE: We have to create the closure beforehand as otherwise it seems
  // the task-local allocator may be used and we end up violating stack-discipline
  // when releasing the handler closure vs. the record.
  let handler0: (UInt8) -> Void = {
    handler(TaskPriority(rawValue: $0))
  }
  let record = _taskAddPriorityEscalationHandler(handler: handler0)
  defer { _taskRemovePriorityEscalationHandler(record: record) }

  return try await operation()
}

func withTaskCancellationHandler<T>(
  isolation: isolated (any Actor)? = #isolation,
  operation: () async throws -> T,
  onCancel handler: @Sendable () -> Void
) async rethrows -> T {
  try await withTaskCancellationHandler(operation: operation, onCancel: handler, isolation: isolation)
}

extension UnsafeCurrentTask {
  static func escalatePriority(_ task: UnsafeCurrentTask, to newPriority: TaskPriority) {
    let _task = Mirror(reflecting: task).children.first(where: { $0.label == "_task" })!.value as! Builtin.NativeObject
    _taskEscalate(_task, newPriority: newPriority.rawValue)
  }
}
