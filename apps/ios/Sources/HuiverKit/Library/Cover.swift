import Foundation

/// Placeholder covers: a book's id picks one of eight two-stop gradients.
///
/// A port of `packages/shared/src/cover.ts`, hash included. The point of
/// porting the hash rather than inventing a new one is that a book keeps its
/// colour across all three apps — the same book is the same green everywhere,
/// which is most of what makes a shelf recognisable at a glance.
public enum Cover {
    /// `(from, to)` as 24-bit RGB, in the same order as the TypeScript array.
    public static let gradients: [(UInt32, UInt32)] = [
        (0x8c_5a_3a, 0x3f_2d_23),  // leather
        (0x5a_6e_4e, 0x26_30_1f),  // moss
        (0x4e_5d_78, 0x23_2b_3a),  // slate blue
        (0x7a_4e_63, 0x33_1f_2b),  // plum
        (0x3e_6b_6b, 0x1c_32_32),  // teal
        (0x8a_6a_3b, 0x3a_2d_18),  // ochre
        (0x6b_4a_7a, 0x2b_1d_33),  // violet
        (0x84_50_50, 0x36_1f_1f),  // brick
    ]

    /// The TypeScript hash, reproduced exactly.
    ///
    /// `hash * 31 + charCode` truncated to a signed 32-bit integer at every
    /// step, which is what JavaScript's `| 0` does. Swift traps on overflow
    /// instead of wrapping, so the arithmetic is done in `Int32` with the
    /// wrapping operators — and `abs` is applied to the truncated value, so
    /// `Int32.min` has to be handled rather than trapped on.
    ///
    /// JavaScript's `charCodeAt` returns UTF-16 code units, so the input is
    /// iterated as UTF-16 rather than as characters.
    public static func index(for id: String) -> Int {
        var hash: Int32 = 0
        for unit in id.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        let magnitude = hash == Int32.min ? Int32.max : abs(hash)
        return Int(magnitude) % gradients.count
    }

    public static func gradient(for id: String) -> (UInt32, UInt32) {
        gradients[index(for: id)]
    }

    /// The letter drawn on a placeholder cover: the title's first letter, with a
    /// leading article dropped so a shelf is not all T's.
    public static func initial(for title: String) -> String {
        let stripped = title.replacing(
            try! Regex("^(the|a|an)\\s+").ignoresCase(),
            with: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = stripped.first else { return "?" }
        return first.uppercased()
    }
}
