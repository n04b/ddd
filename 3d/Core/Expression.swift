//
//  Expression.swift
//  Арифметика в числовых полях: «20+5», «60/2-1,5», «=(40-2*2.4)».
//  Задел под параметрические формулы.
//

import Foundation

nonisolated enum ExpressionEvaluator {
    static func evaluate(_ text: String) -> Double? {
        var source = text.lowercased()
        for unit in ["мм", "mm", "°", "deg"] {
            source = source.replacingOccurrences(of: unit, with: "")
        }
        source = source
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "−", with: "-")
        if source.hasPrefix("=") { source.removeFirst() }

        var parser = Parser(chars: Array(source.filter { !$0.isWhitespace }))
        guard !parser.chars.isEmpty,
              let value = parser.expression(),
              parser.index == parser.chars.count,
              value.isFinite else { return nil }
        return value
    }

    nonisolated private struct Parser {
        let chars: [Character]
        var index = 0

        init(chars: [Character]) {
            self.chars = chars
        }

        private var current: Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = current, op == "+" || op == "-" {
                index += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = factor() else { return nil }
            while let op = current, op == "*" || op == "/" {
                index += 1
                guard let rhs = factor() else { return nil }
                if op == "*" {
                    value *= rhs
                } else {
                    guard rhs != 0 else { return nil }
                    value /= rhs
                }
            }
            return value
        }

        mutating func factor() -> Double? {
            guard let c = current else { return nil }
            if c == "-" {
                index += 1
                return factor().map { -$0 }
            }
            if c == "+" {
                index += 1
                return factor()
            }
            if c == "(" {
                index += 1
                guard let value = expression(), current == ")" else { return nil }
                index += 1
                return value
            }
            return number()
        }

        mutating func number() -> Double? {
            let start = index
            while let c = current, c.isASCII, c.isNumber || c == "." {
                index += 1
            }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }
}
