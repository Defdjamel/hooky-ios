// La page de démonstration : ouvrir la conversation, dire qui est
// l'utilisateur (identify, « Se connecter » avec un userId et des données
// libres, setAttributes), envoyer un événement de stats (track), oublier
// la conversation (reset). La bulle flotte en bas à droite (.hookyBubble()).
import SwiftUI
import Hooky

struct ContentView: View {
    @ObservedObject private var hooky = Hooky.shared
    @State private var name = ""
    @State private var email = ""
    @State private var identified = false
    @State private var tracked = 0

    private var fr: Bool { Locale.preferredLanguages.first?.hasPrefix("fr") == true }
    private func l(_ en: String, _ french: String) -> String { fr ? french : en }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(l("Add a native chat to your app in three lines. Tap the bubble, or use the buttons below.",
                           "Une conversation native dans ton app, en trois lignes. Touche la bulle, ou essaie les boutons ci-dessous."))
                        .font(.body)
                        .foregroundColor(.secondary)

                    card(l("Conversation", "Conversation"), symbol: "bubble.left.and.bubble.right.fill") {
                        HStack {
                            Text(l("Unread messages", "Messages non lus"))
                            Spacer()
                            Text("\(hooky.unreadCount)")
                                .font(.body.monospacedDigit().weight(.semibold))
                                .accessibilityIdentifier("exemple.unread")
                        }
                        Button { Hooky.open() } label: {
                            Label(l("Open the chat", "Ouvrir la conversation"), systemImage: "message.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("exemple.open")
                    }

                    card("identify", symbol: "person.crop.circle.fill") {
                        TextField(l("Name", "Prénom"), text: $name)
                            .textContentType(.givenName)
                            .textFieldStyle(.roundedBorder)
                        TextField(l("Email", "E-mail"), text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Hooky.identify(name: name, email: email)
                            identified = true
                        } label: {
                            Label(identified ? l("Identified", "Identifié") : l("Identify", "Identifier"),
                                  systemImage: identified ? "checkmark.circle.fill" : "person.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(name.isEmpty && email.isEmpty)
                        .accessibilityIdentifier("exemple.identify")

                        // Un compte de l'app : son identifiant et des données libres, vues
                        // par l'équipe sur la fiche de la conversation.
                        Text(l("Signs in as user “demo-42” (plan, cart, beta tester).",
                               "Connecte l’utilisateur « demo-42 » (formule, panier, bêta-testeur)."))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            Hooky.identify(name: name.isEmpty ? "Lila" : name,
                                           email: email.isEmpty ? "lila@example.com" : email,
                                           userId: "demo-42",
                                           attributes: ["plan": "Pro", "cart": 49.9, "beta": true])
                            identified = true
                        } label: {
                            Label(l("Sign in", "Se connecter"), systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("exemple.signin")
                        Button {
                            Hooky.setAttributes(["cart": .number(Double(Int.random(in: 10...200))), "last_screen": "Checkout"])
                        } label: {
                            Label(l("Update the cart (setAttributes)", "Changer le panier (setAttributes)"), systemImage: "cart")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("exemple.attributes")
                    }

                    card("track", symbol: "chart.bar.fill") {
                        Text(l("Sends “demo_purchase” (value 49) to the site’s stats.",
                               "Envoie « demo_purchase » (valeur 49) aux stats du site."))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            Hooky.track("demo_purchase", value: 49, properties: ["plan": "pro", "source": "ios-example"])
                            tracked += 1
                        } label: {
                            Label(tracked > 0 ? l("Sent ×\(tracked)", "Envoyé ×\(tracked)") : l("Track an event", "Envoyer un événement"),
                                  systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("exemple.track")
                    }

                    Button(role: .destructive) {
                        Hooky.reset()
                        identified = false
                    } label: {
                        Label(l("Reset (log out)", "Oublier la conversation (déconnexion)"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("exemple.reset")
                }
                .padding(20)
                .padding(.bottom, 80)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(hooky.siteName ?? "Hooky")
        }
        .navigationViewStyle(.stack)
    }

    private func card<C: View>(_ title: String, symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}
