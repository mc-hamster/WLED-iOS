import SwiftUI

@main
struct WLEDNativeApp: App {
    static let dateLastUpdateKey = "lastUpdateReleasesDate"
    
    let persistenceController = PersistenceController.shared
    @StateObject private var connections = DeviceWebsocketListViewModel(context: PersistenceController.shared.container.viewContext)

    private var isolatesHostedTests: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["BLE_HIL"] == "1" || environment["BLE_HIL_ISOLATE_APP"] == "1"
        #else
        return false
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            if isolatesHostedTests {
                // Hosted unit tests must not connect saved devices either. The
                // hardware suite separately opts in before owning the BLE peer.
                ProgressView("Running automated tests")
            } else {
                DeviceListView(sharedViewModel: connections)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    .onAppear {
                        refreshVersionsSync()
                    }
            }
        }
    }
    
    private func refreshVersionsSync() {
        Task {
            // Only update automatically from Github once per 24 hours to avoid rate limits
            // and reduce network usage.
            let date = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: WLEDNativeApp.dateLastUpdateKey))
            var dateComponent = DateComponents()
            dateComponent.day = 1
            let dateToRefresh = Calendar.current.date(byAdding: dateComponent, to: date)
            let dateNow = Date()
            guard let dateToRefresh = dateToRefresh else {
                return
            }
            if dateNow <= dateToRefresh {
                return
            }
            print("Refreshing available Releases")
            await ReleaseService(context: persistenceController.container.viewContext).refreshVersions()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: WLEDNativeApp.dateLastUpdateKey)
        }
    }
}
