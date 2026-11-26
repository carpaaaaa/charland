import Foundation

extension Vocabulary {
    /// I nomi di serie: app, servizi e sigle che si dicono spesso e che un motore vocale, in mezzo a una frase in
    /// italiano, scrive male o staccati («c'è GPT», «test flight», «X code»). Si accende e si spegne nelle
    /// impostazioni; le parole di chi usa l'app si aggiungono a queste e pesano di più.
    ///
    /// Regola dell'elenco: solo nomi propri. Un marchio che è anche una parola comune in italiano o in inglese
    /// («Slack», «Notion», «Word», «Zoom», «Safari», «Outlook», le «API» che in italiano volano) qui non sta, perché
    /// finirebbe con la maiuscola anche quando è una parola qualunque: chi lo usa lo aggiunge al suo vocabolario.
    public static let common: [String] = [
        // Intelligenze artificiali
        "ChatGPT", "OpenAI", "Claude", "Claude Code", "Anthropic", "Gemini", "Midjourney", "DeepSeek", "NotebookLM",
        "Codex", "Hugging Face",
        // Apple
        "iPhone", "iPad", "MacBook", "AirPods", "AirTag", "AirDrop", "iCloud", "iMessage", "FaceTime", "CarPlay",
        "App Store", "TestFlight", "Xcode", "SwiftUI", "Siri", "macOS", "iOS", "iPadOS", "watchOS", "Apple Watch",
        "Apple Music", "Apple TV",
        // Sviluppo
        "GitHub", "GitLab", "Vercel", "Cloudflare", "Supabase", "Firebase", "Next.js", "Node.js", "TypeScript",
        "JavaScript", "PostgreSQL", "VS Code", "WordPress", "Shopify", "Figma", "JSON", "HTML", "CSS", "SQL", "PDF",
        "USB", "Wi-Fi", "Bluetooth",
        // App e servizi
        "WhatsApp", "Instagram", "TikTok", "YouTube", "Spotify", "Netflix", "Google", "Gmail", "Google Maps",
        "Google Drive", "LinkedIn", "Facebook", "Reddit", "Pinterest", "PayPal", "PowerPoint", "Photoshop",
        "Dropbox", "Obsidian", "Canva", "Airbnb", "eBay", "Wikipedia", "Revolut", "Satispay",
    ]
}
