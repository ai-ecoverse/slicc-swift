func isTextContentType(_ contentType: String) -> Bool {
  if contentType.isEmpty { return false }
  let normalized = contentType.lowercased()
  return normalized.hasPrefix("text/")
    || normalized.contains("json")
    || normalized.contains("xml")
    || normalized.contains("javascript")
    || normalized.contains("ecmascript")
    || normalized.contains("html")
    || normalized.contains("css")
    || normalized.contains("svg")
}
