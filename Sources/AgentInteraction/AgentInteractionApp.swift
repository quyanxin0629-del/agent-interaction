import SwiftUI

private typealias AppState<Value> = State<Value>

@main
@MainActor
struct AgentInteractionApp: App {
    @AppState private var model = WorkflowModel()

    var body: some Scene {
        WindowGroup("多 Agent 协作台", id: "workspace") {
            WorkflowView(model: model)
                .frame(minWidth: 560, minHeight: 480)
        }
        .defaultSize(width: 730, height: 630)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
