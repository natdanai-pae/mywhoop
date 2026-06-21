import Foundation
import CryptoKit

/// Section-level sync (the E2EE sync design P5). Instead of one whole-blob `Envelope` per account, the snapshot is
/// split by its top-level keys into a few named SECTIONS (e.g. history / workouts / chat / scans). Each section is
/// encrypted into its own `Envelope` with its own HLC version, so a change to one section re-uploads ONLY that
/// section — the bandwidth win at scale. The crypto envelope is identical; section-level just stores several.
///
/// Pure + deterministic (canonical sorted-key JSON), so it's fully testable. The split→merge round-trip is lossless.
public enum SectionSplitter {
  public enum SplitError: Error, Equatable { case notAnObject, duplicateKey }

  /// Split a JSON object into sections. `routes` maps a top-level KEY → section name; any key not in `routes` goes
  /// to `fallback`. Each section is a canonical (sorted-keys) JSON object containing just its keys.
  public static func split(_ snapshot: Data, routes: [String: String], fallback: String) throws -> [String: Data] {
    guard let obj = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else { throw SplitError.notAnObject }
    var buckets: [String: [String: Any]] = [:]
    for (k, v) in obj { buckets[routes[k] ?? fallback, default: [:]][k] = v }
    var out: [String: Data] = [:]
    for (section, dict) in buckets {
      out[section] = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }
    return out
  }

  /// Recombine sections into one canonical JSON object (the inverse of `split`). Throws `.duplicateKey` if two
  /// sections claim the same top-level key — a clean `split` never produces that, so it signals a corrupt/mixed set.
  public static func merge(_ sections: [String: Data]) throws -> Data {
    var combined: [String: Any] = [:]
    for (_, data) in sections {
      guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SplitError.notAnObject }
      for (k, v) in dict {
        guard combined[k] == nil else { throw SplitError.duplicateKey }
        combined[k] = v
      }
    }
    return try JSONSerialization.data(withJSONObject: combined, options: [.sortedKeys])
  }

  /// Which sections changed by content vs a previous split (added, modified, or removed) → only these re-upload.
  public static func changedSections(old: [String: Data], new: [String: Data]) -> Set<String> {
    var changed = Set<String>()
    for (s, d) in new where old[s] != d { changed.insert(s) }     // added or modified
    for s in old.keys where new[s] == nil { changed.insert(s) }   // removed
    return changed
  }

  /// SHA-256 hex of a section's canonical bytes — its content address.
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A snapshot's MANIFEST: the version it represents + the content digest of every section. The manifest is the
  /// LAST thing uploaded (after all changed sections), so it only ever names a fully-uploaded, causally-consistent
  /// set — exactly like P4 flips the D1 pointer last.
  public struct Manifest: Codable, Equatable, Sendable {
    public let version: String                 // HLC.packed of this snapshot
    public let digests: [String: String]       // section → content digest
    public init(version: String, digests: [String: String]) { self.version = version; self.digests = digests }
  }

  public static func manifest(version: HLC, sections: [String: Data]) -> Manifest {
    Manifest(version: version.packed, digests: sections.mapValues(digest))
  }

  /// TORN-READ PROTECTION: a fetched section set is safe to `merge` ONLY if it has exactly the manifest's sections
  /// and every digest matches. If a section's upload is still in flight (stale/missing), this returns false and the
  /// puller must wait/retry instead of merging a snapshot that never existed on any device.
  public static func isConsistent(_ manifest: Manifest, sections: [String: Data]) -> Bool {
    guard Set(sections.keys) == Set(manifest.digests.keys) else { return false }
    return sections.allSatisfy { manifest.digests[$0.key] == digest($0.value) }
  }
}
