import SwiftUI
import CharlandCore

/// Dentro un'attività aperta, le altre attività in corso, come le pillole della casa: un tocco apre quella.
/// Così con tre attività accese si vede tutto anche a isola aperta (carpa: «si devono vedere ovviamente anche
/// all'interno le attività»), e si passa dall'una all'altra senza chiudere.
struct ActivitySwitcher: View {
    let model: IslandModel
    let ids: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ids, id: \.self) { id in
                if let content = model.contents[id] {
                    ActivityPill(pill: HomePill(id: id, content: content)) {
                        // la stessa strada delle pillole della casa
                        model.onAction("open:\(id)", IslandState.homeID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
