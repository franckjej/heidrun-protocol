 // MARK: - Threaded news

    public func fetchNewsBundles(at path: RemotePath) async throws -> [NewsBundle] {
        // transID 370. Reply contains 0+ newsBundleEntry(323) fields.
        let reply = try await sendExpectingReply(
            transactionID: 370,
            fields: [.path(.newsPath, path, encoding: stringEncoding)]
        )
        return reply
            .filter { $0.key == HotlineObjectKey.newsBundleEntry.rawValue }
            .compactMap { NewsBundleEntryCodec.decode($0.data, encoding: stringEncoding) }
    }

    public func fetchNewsThreads(at path: RemotePath) async throws -> [NewsThread] {
        // transID 371. Reply carries a single newsThreadList(321) blob.
        let reply = try await sendExpectingReply(
            transactionID: 371,
            fields: [.path(.newsPath, path, encoding: stringEncoding)]
        )
        guard let blob = reply.first(.newsThreadList) else { return [] }
        return NewsThreadListCodec.decode(blob.data, encoding: stringEncoding)
    }

    public func fetchNewsThread(at path: RemotePath, threadID: UInt16, type: String) async throws -> NewsThread {
        // transID 400, [newsPath(325), articleID(326), type(327)].
        // Reply carries a single thread's fields: parent/prev/next ids,
        // post date(330), and one element with type(327), title(328),
        // author(329), data(333). HEClientReceive.m parses them one by
        // one and stuffs them into a dictionary; we collapse to a typed
        // NewsThread with a single ThreadElement.
        let reply = try await sendExpectingReply(
            transactionID: 400,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, threadID),
                .string(.newsType, type, encoding: stringEncoding)
            ]
        )
        let parentID = reply.uint16(.newsParentThread) ?? 0
        let postDate = reply.date(.newsDate) ?? Date.distantPast

        var elements: [ThreadElement] = []
        let elementTitle = reply.string(.newsTitle, encoding: stringEncoding)
        let elementBody  = reply.string(.newsData, encoding: stringEncoding)
        if elementTitle != nil || elementBody != nil {
            let bodyBytes = reply.first(.newsData)?.data.count ?? 0
            elements.append(ThreadElement(
                title: elementTitle ?? "",
                author: reply.string(.newsAuthor, encoding: stringEncoding) ?? "",
                mimeType: reply.string(.newsType, encoding: stringEncoding) ?? ThreadElement.plainTextType,
                size: UInt16(clamping: bodyBytes),
                body: elementBody ?? ""
            ))
        }

        return NewsThread(
            threadID: threadID,
            parentID: parentID,
            postDate: postDate,
            elements: elements
        )
    }

    public func deleteNewsBundle(at path: RemotePath) async throws {
        // transID 380, no-reply, [newsPath(325)].
        try await sendNoReply(
            transactionID: 380,
            fields: [.path(.newsPath, path, encoding: stringEncoding)]
        )
    }

    public func deleteNewsThread(at path: RemotePath, threadID: UInt16, cascade: Bool) async throws {
        // transID 411, no-reply, [newsPath(325), articleID(326), deleteAll(337)].
        try await sendNoReply(
            transactionID: 411,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, threadID),
                .uint16(.newsDeleteAll, cascade ? 1 : 0)
            ]
        )
    }

    public func createNewsBundle(at path: RemotePath, name: String, isCategory: Bool) async throws {
        // transID 381 for bundles, 382 for categories.
        // For a bundle the name uses fileName (201); for a category it uses
        // newsCategoryName (322), per HEClient.m line 1229.
        let transactionID: UInt16 = isCategory ? 382 : 381
        let nameKey: HotlineObjectKey = isCategory ? .newsCategoryName : .fileName
        try await sendNoReply(
            transactionID: transactionID,
            fields: [
                .string(nameKey, name, encoding: stringEncoding),
                .path(.newsPath, path, encoding: stringEncoding)
            ]
        )
    }

    public func postNewsThread(
        at path: RemotePath,
        parentThreadID: UInt16,
        title: String,
        type: String,
        body: String
    ) async throws {
        // transID 410, no-reply, 6 fields:
        //   newsPath(325), articleID(326), title(328), articleFlags(334=0),
        //   type(327), body(333).
        try await sendNoReply(
            transactionID: 410,
            fields: [
                .path(.newsPath, path, encoding: stringEncoding),
                .uint16(.newsArticleID, parentThreadID),
                .string(.newsTitle, title, encoding: stringEncoding),
                .uint16(.newsArticleFlags, 0),
                .string(.newsType, type, encoding: stringEncoding),
                .string(.newsData, body, encoding: stringEncoding)
            ]
        )
    }