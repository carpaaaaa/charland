import Foundation

/// I calcoli scritti nella barra: `12*7`, `(3,5+2)^2`, `20% * 340`, `sqrt 2`, `2π`.
///
/// Un analizzatore nostro, piccolo: `NSExpression` si ferma con un'eccezione su un'espressione scritta a metà (cioè a
/// ogni lettera) e accetta cose che non sono calcoli. Qui o il testo è un calcolo intero, o niente.
enum SearchCalculator {
    /// Il risultato già scritto per la riga, o `nil` se il testo non è un calcolo.
    static func evaluate(_ text: String) -> (value: Double, display: String)? {
        var source = text.trimmingCharacters(in: .whitespaces)
        // «2+2=»: l'uguale in fondo è l'abitudine della calcolatrice, non un errore.
        while source.hasSuffix("=") { source = String(source.dropLast()).trimmingCharacters(in: .whitespaces) }
        // Un testo incollato enorme non è un calcolo (e le parentesi annidate farebbero ricorrere troppo l'analizzatore).
        guard source.count <= 200 else { return nil }
        // Date e versioni («2024-11», «12/05/2024», «3.2.1») non sono calcoli: Invio deve aprire il file con quel nome.
        // «100-25» e «9/3» invece sì: due numeri soli restano un calcolo, tranne anno-mese.
        if source.range(of: #"^\d{4}-\d{1,2}$"#, options: .regularExpression) != nil { return nil }
        if source.range(of: #"^\d{1,4}([-/.])\d{1,4}\1\d{1,4}$"#, options: .regularExpression) != nil { return nil }
        // Almeno un'operazione o una funzione: un numero da solo non è un calcolo da mostrare.
        guard source.count >= 2, source.contains(where: { "+-*/×÷^%(√πx".contains($0) }) || hasFunction(source) else { return nil }
        var parser = Parser(Array(source.lowercased()))
        guard let value = parser.parse(), value.isFinite else { return nil }
        // «-5» o «(4)» da soli non sono calcoli.
        if Double(source.replacingOccurrences(of: ",", with: ".")) != nil { return nil }
        return (value, format(value))
    }

    private static func hasFunction(_ s: String) -> Bool {
        let lower = s.lowercased()
        return ["sqrt", "sin", "cos", "tan", "log", "ln", "abs", "round", "pi"].contains { lower.contains($0) }
    }

    /// I formattatori si creano una volta: crearne uno a ogni lettera costava qualche millisecondo. Usati solo dal thread
    /// principale (la barra).
    private static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        return formatter
    }()

    private static let scientific: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .scientific
        formatter.maximumFractionDigits = 8
        return formatter
    }()

    static func format(_ value: Double) -> String {
        let formatter = abs(value) >= 1e15 || (abs(value) < 1e-9 && value != 0) ? scientific : decimal
        formatter.usesGroupingSeparator = abs(value) >= 10_000
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Precedenze classiche: `+ -`, poi `* / ×  ÷` e la moltiplicazione sottintesa (`2π`, `3(4+1)`), poi `^` (a destra),
    /// poi il meno davanti, poi `%` dopo un numero (vale un centesimo). Virgola e punto sono tutti e due decimali.
    private struct Parser {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func parse() -> Double? {
            guard let value = expression() else { return nil }
            skipSpaces()
            return index == chars.count ? value : nil
        }

        private mutating func skipSpaces() {
            while index < chars.count, chars[index] == " " { index += 1 }
        }

        private mutating func peek() -> Character? {
            skipSpaces()
            return index < chars.count ? chars[index] : nil
        }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                index += 1
                guard let rhs = term() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let c = peek() {
                if c == "*" || c == "×" || c == "x" || c == "/" || c == "÷" || c == ":" {
                    index += 1
                    guard let rhs = power() else { return nil }
                    if c == "/" || c == "÷" || c == ":" {
                        guard rhs != 0 else { return nil }
                        value /= rhs
                    } else {
                        value *= rhs
                    }
                } else if c == "(" || c == "π" || c == "√" || c.isLetter {
                    // Moltiplicazione sottintesa: 2π, 3(1+2), 2 sqrt 9.
                    guard let rhs = power() else { return nil }
                    value *= rhs
                } else {
                    break
                }
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if let c = peek(), c == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if let c = peek(), c == "-" || c == "+" {
                index += 1
                guard let value = unary() else { return nil }
                return c == "-" ? -value : value
            }
            return postfix()
        }

        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            while let c = peek(), c == "%" {
                index += 1
                value /= 100
            }
            return value
        }

        private mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                index += 1
                guard let value = expression(), peek() == ")" else { return nil }
                index += 1
                return value
            }
            if c == "√" {
                index += 1
                guard let value = postfix(), value >= 0 else { return nil }
                return value.squareRoot()
            }
            if c == "π" { index += 1; return .pi }
            if c.isNumber || c == "." || c == "," { return number() }
            if c.isLetter { return function() }
            return nil
        }

        private mutating func number() -> Double? {
            var text = ""
            var separators = 0
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    text.append(c)
                } else if c == "." || c == "," {
                    separators += 1
                    text.append(".")
                } else {
                    break
                }
                index += 1
            }
            // «1.000.000»: più separatori di fila sono le migliaia.
            if separators > 1 { text = text.replacingOccurrences(of: ".", with: "") }
            return Double(text)
        }

        private mutating func function() -> Double? {
            var name = ""
            while index < chars.count, chars[index].isLetter { name.append(chars[index]); index += 1 }
            switch name {
            case "pi": return .pi
            case "e": return M_E
            default: break
            }
            let functions: [String: (Double) -> Double?] = [
                "sqrt": { $0 >= 0 ? $0.squareRoot() : nil },
                "sin": { sin($0) }, "cos": { cos($0) }, "tan": { tan($0) },
                "log": { $0 > 0 ? log10($0) : nil }, "ln": { $0 > 0 ? log($0) : nil },
                "abs": { abs($0) }, "round": { $0.rounded() },
            ]
            guard let apply = functions[name], let argument = power() else { return nil }
            return apply(argument)
        }
    }
}
