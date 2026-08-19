import from re { search, split }

def:pub fuzzyMatch(query: str, text: str) -> any {
    queryLower: str = query.lower();
    textLower: str = text.lower();
    matchQuery = lambda (normalizedQuery: str) -> any { if (len(normalizedQuery) == 0) {     return {"matches": True, "score": 0}; } if (len(normalizedQuery) > len(textLower)) {     return {"matches": False, "score": 0}; } queryIndex = 0; score: float = float(0); lastMatchIndex = -1; consecutiveMatches = 0; i: int = 0; while ((i < len(textLower)) and (queryIndex < len(normalizedQuery))) {     if (textLower[i] == normalizedQuery[queryIndex]) {         isWordBoundary = ((i == 0) or (search(r"[\s\-_./:]", (textLower[(i - 1)] as any)) is not None));         if (lastMatchIndex == (i - 1)) {             consecutiveMatches += 1;             score = float(score - (consecutiveMatches * 5));         }         else {             consecutiveMatches = 0;             if (lastMatchIndex >= 0) {                 score = float(score + (((i - lastMatchIndex) - 1) * 2));             }         }         if isWordBoundary {             score = float(score - 10);         }         score = float(score + (i * 0.1));         lastMatchIndex = i;         queryIndex += 1;     }     i += 1; } if (queryIndex < len(normalizedQuery)) {     return {"matches": False, "score": 0}; } if (normalizedQuery == textLower) {     score = float(score - 100); } return {"matches": True, "score": score}; };
    primaryMatch = matchQuery(queryLower);
    if (primaryMatch["matches"] as bool) {
        return primaryMatch;
    }
    alphaNumericMatch = search(r"^(?P<letters>[a-z]+)(?P<digits>[0-9]+)$", queryLower);
    numericAlphaMatch = search(r"^(?P<digits>[0-9]+)(?P<letters>[a-z]+)$", queryLower);
    swappedQuery = (f"{((alphaNumericMatch.groupdict().get('digits') as str) if (alphaNumericMatch.groupdict().get('digits') as str) is not None else "")}{((alphaNumericMatch.groupdict().get('letters') as str) if (alphaNumericMatch.groupdict().get('letters') as str) is not None else "")}" if alphaNumericMatch else (f"{((numericAlphaMatch.groupdict().get('letters') as str) if (numericAlphaMatch.groupdict().get('letters') as str) is not None else "")}{((numericAlphaMatch.groupdict().get('digits') as str) if (numericAlphaMatch.groupdict().get('digits') as str) is not None else "")}" if numericAlphaMatch else ""));
    if not swappedQuery {
        return primaryMatch;
    }
    swappedMatch = matchQuery(swappedQuery);
    if not (swappedMatch["matches"] as bool) {
        return primaryMatch;
    }
    return {"matches": True, "score": ((swappedMatch["score"] as float) + 5)};
}

def:pub fuzzyFilter(items: list[any], query: str, getText: any) -> list[any] {
    if not query.strip() {
        return items;
    }
    tokens = [t for t in split(r"[\s/]+", query.strip()) if (len(t) > 0)];
    if (len(tokens) == 0) {
        return items;
    }
    results: list[dict[str, any | float]] = [];
    for item in items {
        text = getText(item);
        totalScore: float = float(0);
        allMatch: bool = True;
        for token in tokens {
            match_j = fuzzyMatch(token, text);
            if (match_j["matches"] as bool) {
                totalScore = float(totalScore + (match_j["score"] as float));
            }
            else {
                allMatch = False;
                break;
            }
        }
        if allMatch {
            results.append({"item": item, "totalScore": totalScore});
        }
    }
    results.sort(key=lambda (_jx_sort: any) -> any { return _jx_sort["totalScore"]; });
    return [(r["item"] as any) for r in results];
}
