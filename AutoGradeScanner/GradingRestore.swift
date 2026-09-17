import Foundation

// Bringing a teacher's own grading back down after they sign in.
//
// Grading is filed to disk the moment it happens and uploaded separately, so
// for most of this app's life the device was the original and the server the
// copy. Signing out now deletes the device's side — it has to, because two
// teachers share the iPad and what one of them graded this afternoon is a list
// of children and how each of them did. That makes the server the original,
// and this is the other half of that bargain: sign back in and your own work
// is still there.
//
// What comes back is the record, not the session. The server stores what was
// graded and how — question, expected answer, what the model read, what the
// teacher said instead — but never stored where on the page each cell sits,
// because the device drawing the review screen always had the template in
// hand. So the geometry is recovered from the template here, which is also why
// this runs after the template sync rather than beside it.
@MainActor
enum GradingRestore {

    /// Guards against two restores overlapping. `Credentials.didChange` fires
    /// on enrolment and again on anything that touches the credential, and a
    /// second pass while the first is still writing would race it to the same
    /// files.
    private static var isRunning = false

    /// Whether a pass has got all the way through since launch.
    ///
    /// The restore that matters happens the moment someone signs in, and that
    /// is the one most likely to fail: a teacher signing in is often a teacher
    /// on a network they have just joined. So coming back to the app retries
    /// until one pass completes, and then stops — a list request on every
    /// return to the foreground, forever, would be polling dressed up as
    /// recovery.
    private static var hasCompleted = false

    /// Called when the app comes forward. Does nothing once a pass has
    /// succeeded, so the cost is paid once per launch at most.
    static func runIfNeeded() async {
        guard !hasCompleted else { return }
        await run()
    }

    static func run() async {
        guard !isRunning else { return }
        guard Credentials.isEnrolled, !DemoData.isEnabled, ServerConfig.isConfigured else { return }

        isRunning = true
        // A pass is only ever "already done" for the person it was done for.
        // Signing out and back in as somebody else reaches here through the
        // sign-in path, which does not consult the flag — but the retry on
        // returning to the foreground does, and without this it would read the
        // previous teacher's success and skip the new teacher's retry for the
        // rest of the launch.
        hasCompleted = false

        let store = GradingStore.shared
        store.beginRestoring()
        defer {
            store.endRestoring()
            isRunning = false
        }

        guard let summaries = try? await APIClient.shared.listSessions() else { return }

        // Only what is missing. A paper already here is the richer copy — it
        // has its crops, and the rectangles it was actually graded against
        // rather than the ones the template holds today — so replacing it with
        // the server's account of it would be a downgrade performed on every
        // sign-in.
        let known = store.knownIDs
        let wanted = summaries.filter { !known.contains($0.client_uuid) }
        guard !wanted.isEmpty else {
            hasCompleted = true
            return
        }

        // Resolving a template can hit the network; a stack of thirty papers
        // is usually two or three templates between them.
        var templates: [Int: ResolvedTemplate?] = [:]
        var restored: [(UUID, [APIClient.SessionAnswerDTO])] = []

        // Oldest first, so a restore interrupted halfway leaves the history
        // contiguous rather than pocked with holes.
        for summary in wanted.sorted(by: { $0.scanned_at < $1.scanned_at }) {
            guard let dto = try? await APIClient.shared.getSession(clientUUID: summary.client_uuid)
            else { continue }

            let template: ResolvedTemplate?
            if let cached = templates[dto.template_id] {
                template = cached
            } else {
                template = try? await TemplateStore.shared.resolve(id: dto.template_id)
                // `updateValue`, not `templates[id] = template`. The value type
                // is itself optional, so plain subscript assignment of a nil
                // reads as "remove this key" — and a template that cannot be
                // resolved, which is exactly the case worth remembering, would
                // be retried over the network once per paper.
                templates.updateValue(template, forKey: dto.template_id)
            }

            store.restore(paper(from: dto, template: template))
            restored.append((dto.client_uuid, dto.answers))
        }

        // Only when every record asked for actually arrived. Half a term's
        // grading is not a finished restore, and marking it done would leave
        // the missing half waiting for the next launch — a teacher's own work
        // is worth one more request when they next open the app.
        hasCompleted = restored.count == wanted.count

        // The crops last, separately, and only the ones somebody still has to
        // look at.
        //
        // A crop is worth a download when it is the only way to settle a cell:
        // the model could not read it and no teacher has said what it is. A
        // cell the teacher already corrected is settled — their answer came
        // back with the record — and a cell everyone agreed on never had a
        // crop on the server to begin with. Fetching the whole set instead
        // would be several hundred requests at sign-in to redraw thumbnails
        // beside answers nobody disputes.
        for (id, answers) in restored {
            for answer in answers where needsCrop(answer) {
                guard let imageID = answer.cell_image_id else { continue }
                guard !FileManager.default.fileExists(
                    atPath: store.cellURL(id, question: answer.question_no).path) else { continue }
                guard let png = try? await APIClient.shared.imageContent(id: imageID) else { continue }
                store.restoreCell(id, question: answer.question_no, png: png)
            }
        }
    }

    /// The mirror of `UploadQueue.wantsCrop`, narrowed. That one decides what
    /// is worth keeping; this decides what is worth fetching back, and the
    /// difference is the corrections — already answered, so the picture adds
    /// nothing a teacher would act on.
    private static func needsCrop(_ answer: APIClient.SessionAnswerDTO) -> Bool {
        (answer.teacher_value ?? "").isEmpty && answer.verdict == "unsure"
    }

    // MARK: - Rebuilding one record

    private static func paper(from dto: APIClient.SessionDTO,
                              template: ResolvedTemplate?) -> StoredPaper {
        // Which side each cell is printed on, by position in the page array
        // rather than by the server's `page_index`. Everything downstream —
        // `StoredAnswer.page`, the page switcher, the master it draws on —
        // indexes the array, and a template whose pages were ever numbered
        // from something other than zero would put every box on the wrong
        // sheet in a way that looks entirely plausible.
        var placement: [Int: (rect: [Double], page: Int)] = [:]
        if let template {
            for (slot, page) in template.pages.enumerated() {
                for question in page.questions {
                    placement[question.number] = (
                        [question.box.minX, question.box.minY,
                         question.box.width, question.box.height], slot)
                }
            }
        }

        let answers = dto.answers
            .sorted { $0.question_no < $1.question_no }
            .map { answer -> StoredAnswer in
                let placed = placement[answer.question_no]
                return StoredAnswer(
                    questionNo: answer.question_no,
                    expected: answer.expected,
                    recognized: answer.recognized ?? "",
                    // Stored as the server spells it. The two vocabularies are
                    // the same three words, and `parsedVerdict` reads anything
                    // it does not know as `.unsure` — which asks a human
                    // rather than inventing a grade.
                    verdict: answer.verdict,
                    teacherValue: answer.teacher_value,
                    confidence: answer.confidence,
                    templateRect: placed?.rect,
                    pageIndex: placed?.page)
            }

        // Only when the template was resolvable. A record with no geometry
        // must not claim to have pages: `pagesOrInferred` would otherwise hand
        // the review screen a list of sides whose boxes are all nil, and the
        // screen would spend the rest of its life fetching masters to draw
        // nothing on.
        let pages: [StoredPage]? = template.map { resolved in
            resolved.pages.indices.map { slot in
                StoredPage(index: slot,
                           imageID: resolved.pages[slot].imageID,
                           label: resolved.pageLabel(slot))
            }
        }

        return StoredPaper(
            id: dto.client_uuid,
            templateID: dto.template_id,
            templateTitle: template?.title ?? dto.template_name ?? "考卷 \(dto.template_id)",
            scannedAt: date(dto.scanned_at) ?? Date(),
            answers: answers,
            pages: pages,
            // The server's own timestamp, and the reason this record does not
            // immediately queue itself for upload: `needsUpload` is false the
            // moment this is set. Without it the device would spend the first
            // minute after every sign-in sending the server back the records
            // it had just finished handing over.
            uploadedAt: date(dto.uploaded_at) ?? Date(),
            isDemo: nil,
            revision: 0)
    }

    // MARK: - Dates

    /// ISO-8601 as FastAPI emits it, which is to say with fractional seconds
    /// sometimes and without them other times, and with a `Z` or a `+00:00`
    /// depending on how the value reached the database.
    private static func date(_ text: String) -> Date? {
        for formatter in iso8601 {
            if let parsed = formatter.date(from: text) { return parsed }
        }
        // A naive timestamp, which is what SQLite hands back when a column was
        // written without a zone. Read as UTC, because that is what the server
        // wrote even when it neglected to say so.
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) { return parsed }
        }
        return nil
    }

    private static let iso8601: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return [fractional, whole]
    }()
}
