package com.litter.android.ui

import com.litter.android.state.ChatMessage
import com.litter.android.state.MessageRole
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Locale

internal enum class ToolCallKind(
    val title: String,
) {
    COMMAND_EXECUTION("Command Execution"),
    COMMAND_OUTPUT("Command Output"),
    FILE_CHANGE("File Change"),
    FILE_DIFF("File Diff"),
    MCP_TOOL_CALL("MCP Tool Call"),
    MCP_TOOL_PROGRESS("MCP Tool Progress"),
    WEB_SEARCH("Web Search"),
    COLLABORATION("Collaboration"),
    IMAGE_VIEW("Image View"),
}

internal enum class ToolCallStatus(val label: String, val summarySuffix: String) {
    IN_PROGRESS("In Progress", "in progress"),
    COMPLETED("Completed", "completed"),
    FAILED("Failed", "failed"),
    UNKNOWN("Unknown", "unknown"),
}

internal data class ToolCallKeyValue(
    val key: String,
    val value: String,
)

internal sealed interface ToolCallSection {
    data class KeyValue(
        val label: String,
        val entries: List<ToolCallKeyValue>,
    ) : ToolCallSection

    data class Code(
        val label: String,
        val language: String,
        val content: String,
    ) : ToolCallSection

    data class Json(
        val label: String,
        val content: String,
    ) : ToolCallSection

    data class Diff(
        val label: String,
        val content: String,
    ) : ToolCallSection

    data class Text(
        val label: String,
        val content: String,
    ) : ToolCallSection

    data class ListSection(
        val label: String,
        val items: List<String>,
    ) : ToolCallSection

    data class Progress(
        val label: String,
        val items: List<String>,
    ) : ToolCallSection
}

internal data class ToolCallCardModel(
    val kind: ToolCallKind,
    val title: String,
    val summary: String,
    val status: ToolCallStatus,
    val duration: String?,
    val sections: List<ToolCallSection>,
) {
    val defaultExpanded: Boolean
        get() = status == ToolCallStatus.FAILED
}

internal sealed interface ToolCallParseResult {
    data class Recognized(
        val model: ToolCallCardModel,
    ) : ToolCallParseResult

    data object Unrecognized : ToolCallParseResult
}

internal object ToolCallMessageParser {
    private val leadingKeySet =
        setOf(
            "status",
            "tool",
            "duration",
            "path",
            "kind",
            "query",
            "targets",
            "exit code",
            "directory",
            "approval",
            "error",
        )

    private val namedSectionSet =
        setOf(
            "command",
            "arguments",
            "result",
            "output",
            "prompt",
            "action",
            "progress",
            "error",
        )

    fun parse(message: ChatMessage): ToolCallParseResult {
        if (message.role != MessageRole.SYSTEM) {
            return ToolCallParseResult.Unrecognized
        }
        val system = parseSystemEnvelope(message.text) ?: return ToolCallParseResult.Unrecognized
        val kind = kindFromTitle(system.title) ?: return ToolCallParseResult.Unrecognized
        if (system.body.isBlank()) {
            return ToolCallParseResult.Unrecognized
        }

        val body = parseBody(system.body, kind)
        if (body.metadata.isEmpty() && body.primarySections.isEmpty() && body.auxSections.isEmpty()) {
            return ToolCallParseResult.Unrecognized
        }

        val status = normalizeStatus(body.metadataValue("status"))
        val duration = body.metadataValue("duration")
        val sections =
            buildList {
                if (body.metadata.isNotEmpty()) {
                    add(ToolCallSection.KeyValue(label = "Metadata", entries = body.metadata))
                }
                addAll(body.primarySections)
                addAll(body.auxSections)
            }

        return ToolCallParseResult.Recognized(
            ToolCallCardModel(
                kind = kind,
                title = system.title,
                summary = summaryFor(kind, system.title, status, duration, body),
                status = status,
                duration = duration,
                sections = sections,
            ),
        )
    }

    private data class ParsedSystemMessage(
        val title: String,
        val body: String,
    )

    private data class ParsedFence(
        val language: String,
        val content: String,
    )

    private data class RawSection(
        val label: String?,
        val content: String,
    )

    private data class ParsedBody(
        val metadata: List<ToolCallKeyValue>,
        val primarySections: List<ToolCallSection>,
        val auxSections: List<ToolCallSection>,
        val filePaths: List<String>,
    ) {
        fun metadataValue(key: String): String? {
            val normalizedKey = normalizeToken(key)
            return metadata.firstOrNull { normalizeToken(it.key) == normalizedKey }?.value
        }
    }

    private data class FenceState(
        val marker: Char,
        val length: Int,
    )

    private fun parseSystemEnvelope(text: String): ParsedSystemMessage? {
        val trimmed = text.trim()
        if (!trimmed.startsWith("### ")) {
            return null
        }
        val firstLine = trimmed.lineSequence().firstOrNull() ?: return null
        val title = firstLine.removePrefix("### ").trim()
        if (title.isEmpty()) {
            return null
        }
        val body =
            if (!trimmed.contains('\n')) {
                ""
            } else {
                trimmed.substringAfter('\n').trim()
            }
        return ParsedSystemMessage(title = title, body = body)
    }

    private fun kindFromTitle(title: String): ToolCallKind? {
        val normalized = normalizeToken(title)
        return when {
            normalized.contains("command output") -> ToolCallKind.COMMAND_OUTPUT
            normalized.contains("command execution") || normalized == "command" -> ToolCallKind.COMMAND_EXECUTION
            normalized.contains("file change") -> ToolCallKind.FILE_CHANGE
            normalized.contains("file diff") || normalized == "diff" -> ToolCallKind.FILE_DIFF
            normalized.contains("mcp tool progress") -> ToolCallKind.MCP_TOOL_PROGRESS
            normalized.contains("mcp tool call") || normalized == "mcp" -> ToolCallKind.MCP_TOOL_CALL
            normalized.contains("web search") -> ToolCallKind.WEB_SEARCH
            normalized.contains("collaboration") || normalized.contains("collab") -> ToolCallKind.COLLABORATION
            normalized.contains("image view") || normalized == "image" -> ToolCallKind.IMAGE_VIEW
            else -> null
        }
    }

    private fun parseBody(
        body: String,
        kind: ToolCallKind,
    ): ParsedBody {
        val lines = body.split('\n')
        var index = 0
        val metadata = mutableListOf<ToolCallKeyValue>()
        val filePaths = mutableListOf<String>()
        val auxSections = mutableListOf<ToolCallSection>()

        while (index < lines.size) {
            val trimmed = lines[index].trim()
            if (trimmed.isEmpty()) {
                if (metadata.isEmpty()) {
                    index += 1
                    continue
                }
                index += 1
                break
            }
            if (parseSectionHeader(trimmed) != null) {
                break
            }
            val keyValue = parseKeyValueLine(trimmed) ?: break
            val normalizedKey = normalizeToken(keyValue.key)
            if (!leadingKeySet.contains(normalizedKey)) {
                break
            }

            if (normalizedKey == "targets") {
                val items =
                    keyValue.value
                        .split(',')
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                if (items.isNotEmpty()) {
                    auxSections += ToolCallSection.ListSection(label = "Targets", items = items)
                }
            } else {
                metadata += ToolCallKeyValue(key = keyValue.key, value = keyValue.value)
                if (normalizedKey == "path" && keyValue.value.isNotBlank()) {
                    filePaths += keyValue.value
                }
            }
            index += 1
        }

        val remainder = lines.drop(index).joinToString("\n").trim()
        val primarySections = mutableListOf<ToolCallSection>()

        if (remainder.isNotBlank()) {
            when (kind) {
                ToolCallKind.FILE_CHANGE -> {
                    val parsed = parseFileChangeSections(remainder)
                    primarySections += parsed.sections
                    filePaths += parsed.paths
                }

                else -> {
                    splitNamedSections(remainder).forEach { raw ->
                        appendSection(raw, kind, primarySections, auxSections)
                    }
                }
            }
        }

        if (kind == ToolCallKind.MCP_TOOL_PROGRESS && auxSections.isEmpty() && remainder.isNotBlank()) {
            val items =
                remainder
                    .lineSequence()
                    .map { it.trim() }
                    .filter { it.isNotEmpty() }
                    .toList()
            if (items.isNotEmpty()) {
                auxSections += ToolCallSection.Progress(label = "Progress", items = items)
            }
        }

        return ParsedBody(
            metadata = metadata,
            primarySections = primarySections,
            auxSections = auxSections,
            filePaths = filePaths,
        )
    }

    private data class FileChangeParseResult(
        val sections: List<ToolCallSection>,
        val paths: List<String>,
    )

    private fun parseFileChangeSections(remainder: String): FileChangeParseResult {
        val chunks = splitTopLevel(remainder, separator = "---")
        val sections = mutableListOf<ToolCallSection>()
        val paths = mutableListOf<String>()

        chunks.forEachIndexed { index, chunk ->
            val lines = chunk.split('\n')
            var cursor = 0
            val entryMetadata = mutableListOf<ToolCallKeyValue>()
            while (cursor < lines.size) {
                val trimmed = lines[cursor].trim()
                if (trimmed.isEmpty()) {
                    cursor += 1
                    break
                }
                val keyValue = parseKeyValueLine(trimmed) ?: break
                val normalizedKey = normalizeToken(keyValue.key)
                if (normalizedKey != "path" && normalizedKey != "kind") {
                    break
                }
                entryMetadata += ToolCallKeyValue(key = keyValue.key, value = keyValue.value)
                if (normalizedKey == "path") {
                    paths += keyValue.value
                }
                cursor += 1
            }

            if (entryMetadata.isNotEmpty()) {
                sections += ToolCallSection.KeyValue(label = "Change ${index + 1}", entries = entryMetadata)
            }

            val content = lines.drop(cursor).joinToString("\n").trim()
            if (content.isBlank()) {
                return@forEachIndexed
            }
            val fence = parseSingleFence(content)
            if (fence != null) {
                val language = normalizeToken(fence.language)
                when {
                    language == "diff" -> sections += ToolCallSection.Diff(label = "Diff", content = fence.content)
                    language == "json" -> sections += ToolCallSection.Json(label = "Content", content = fence.content)
                    language == "text" || language.isEmpty() -> sections += ToolCallSection.Text(label = "Content", content = fence.content)
                    else -> sections += ToolCallSection.Code(label = "Content", language = fence.language, content = fence.content)
                }
            } else {
                sections += ToolCallSection.Text(label = "Content", content = content)
            }
        }

        return FileChangeParseResult(sections = sections, paths = paths)
    }

    private fun splitNamedSections(text: String): List<RawSection> {
        val lines = text.split('\n')
        val sections = mutableListOf<RawSection>()
        var currentLabel: String? = null
        val buffer = mutableListOf<String>()
        var sawNamedSection = false
        var fenceState: FenceState? = null

        fun flush() {
            val content = buffer.joinToString("\n").trim()
            if (content.isNotEmpty() || currentLabel != null) {
                sections += RawSection(label = currentLabel, content = content)
            }
            buffer.clear()
        }

        lines.forEach { line ->
            val trimmed = line.trim()
            val header = if (fenceState == null) parseSectionHeader(trimmed) else null
            if (header != null) {
                sawNamedSection = true
                flush()
                currentLabel = header.label
                if (header.inlineValue.isNotBlank()) {
                    buffer += header.inlineValue
                }
                return@forEach
            }

            buffer += line
            fenceState = updateFenceState(line, fenceState)
        }
        flush()

        if (!sawNamedSection) {
            return listOf(RawSection(label = null, content = text.trim()))
        }
        return sections
    }

    private fun splitTopLevel(
        text: String,
        separator: String,
    ): List<String> {
        val lines = text.split('\n')
        val chunks = mutableListOf<String>()
        val buffer = mutableListOf<String>()
        var fenceState: FenceState? = null

        fun flush() {
            val chunk = buffer.joinToString("\n").trim()
            if (chunk.isNotEmpty()) {
                chunks += chunk
            }
            buffer.clear()
        }

        lines.forEach { line ->
            val trimmed = line.trim()
            if (fenceState == null && trimmed == separator) {
                flush()
                return@forEach
            }
            buffer += line
            fenceState = updateFenceState(line, fenceState)
        }
        flush()
        return chunks
    }

    private fun appendSection(
        raw: RawSection,
        kind: ToolCallKind,
        primary: MutableList<ToolCallSection>,
        aux: MutableList<ToolCallSection>,
    ) {
        val label = raw.label?.replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.US) else it.toString() }
        val content = raw.content.trim()
        if (content.isBlank()) {
            return
        }

        if (label != null) {
            when (normalizeToken(label)) {
                "command" -> primary += parseCodeLike(label = "Command", content = content, fallbackLanguage = "bash")
                "arguments" -> primary += parseJsonLike(label = "Arguments", content = content)
                "result" -> primary += parseJsonLike(label = "Result", content = content)
                "output" -> primary += parseOutputLike(label = "Output", content = content)
                "action" -> primary += parseJsonLike(label = "Action", content = content)
                "prompt" -> aux += ToolCallSection.Text(label = "Prompt", content = content)
                "progress" -> {
                    val items =
                        content
                            .lineSequence()
                            .map { it.trim() }
                            .filter { it.isNotEmpty() }
                            .toList()
                    if (items.isNotEmpty()) {
                        aux += ToolCallSection.Progress(label = "Progress", items = items)
                    }
                }

                "error" -> primary += parseOutputLike(label = "Error", content = content)
                else -> primary += ToolCallSection.Text(label = label, content = content)
            }
            return
        }

        when (kind) {
            ToolCallKind.COMMAND_OUTPUT -> primary += parseOutputLike(label = "Output", content = content)
            ToolCallKind.FILE_DIFF -> {
                val fence = parseSingleFence(content)
                if (fence != null && normalizeToken(fence.language) == "diff") {
                    primary += ToolCallSection.Diff(label = "Diff", content = fence.content)
                } else {
                    primary += ToolCallSection.Diff(label = "Diff", content = content)
                }
            }

            ToolCallKind.MCP_TOOL_PROGRESS -> {
                val items =
                    content
                        .lineSequence()
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                        .toList()
                if (items.isNotEmpty()) {
                    aux += ToolCallSection.Progress(label = "Progress", items = items)
                }
            }

            else -> {
                val fence = parseSingleFence(content)
                if (fence != null) {
                    val language = normalizeToken(fence.language)
                    when {
                        language == "json" -> primary += ToolCallSection.Json(label = "Details", content = fence.content)
                        language == "diff" -> primary += ToolCallSection.Diff(label = "Diff", content = fence.content)
                        language == "text" || language.isEmpty() -> primary += ToolCallSection.Text(label = "Details", content = fence.content)
                        else -> primary += ToolCallSection.Code(label = "Details", language = fence.language, content = fence.content)
                    }
                } else {
                    primary += ToolCallSection.Text(label = "Details", content = content)
                }
            }
        }
    }

    private fun parseCodeLike(
        label: String,
        content: String,
        fallbackLanguage: String,
    ): ToolCallSection {
        val fence = parseSingleFence(content)
        if (fence != null) {
            val language = if (fence.language.isBlank()) fallbackLanguage else fence.language
            return ToolCallSection.Code(label = label, language = language, content = fence.content)
        }
        return ToolCallSection.Code(label = label, language = fallbackLanguage, content = content)
    }

    private fun parseJsonLike(
        label: String,
        content: String,
    ): ToolCallSection {
        val fence = parseSingleFence(content)
        if (fence != null) {
            val language = normalizeToken(fence.language)
            return when {
                language == "json" || language.isEmpty() -> ToolCallSection.Json(label = label, content = fence.content)
                language == "diff" -> ToolCallSection.Diff(label = label, content = fence.content)
                else -> ToolCallSection.Code(label = label, language = fence.language, content = fence.content)
            }
        }
        if (looksLikeJson(content)) {
            return ToolCallSection.Json(label = label, content = content)
        }
        return ToolCallSection.Text(label = label, content = content)
    }

    private fun parseOutputLike(
        label: String,
        content: String,
    ): ToolCallSection {
        val fence = parseSingleFence(content)
        if (fence != null) {
            val language = normalizeToken(fence.language)
            return when {
                language == "diff" -> ToolCallSection.Diff(label = label, content = fence.content)
                language == "json" -> ToolCallSection.Json(label = label, content = fence.content)
                language == "text" || language.isEmpty() -> ToolCallSection.Text(label = label, content = fence.content)
                else -> ToolCallSection.Code(label = label, language = fence.language, content = fence.content)
            }
        }
        return ToolCallSection.Text(label = label, content = content)
    }

    private fun summaryFor(
        kind: ToolCallKind,
        title: String,
        status: ToolCallStatus,
        duration: String?,
        body: ParsedBody,
    ): String {
        when (kind) {
            ToolCallKind.COMMAND_EXECUTION, ToolCallKind.COMMAND_OUTPUT -> {
                val command = commandSummary(body.primarySections)
                if (!command.isNullOrBlank()) {
                    var summary = stripShellWrapper(command)
                    if (status == ToolCallStatus.COMPLETED) {
                        summary += " ✓"
                    } else if (status != ToolCallStatus.UNKNOWN) {
                        summary += " (${status.summarySuffix})"
                    }
                    if (!duration.isNullOrBlank()) {
                        summary += " $duration"
                    }
                    return summary
                }
            }

            ToolCallKind.FILE_CHANGE, ToolCallKind.FILE_DIFF -> {
                val firstPath = body.filePaths.firstOrNull()
                if (!firstPath.isNullOrBlank()) {
                    val basename = File(firstPath).name.ifBlank { firstPath }
                    if (body.filePaths.size > 1) {
                        return "$basename +${body.filePaths.size - 1} files"
                    }
                    return basename
                }
            }

            ToolCallKind.MCP_TOOL_CALL, ToolCallKind.MCP_TOOL_PROGRESS -> {
                val tool = body.metadataValue("tool")
                if (!tool.isNullOrBlank()) {
                    if (status == ToolCallStatus.COMPLETED) {
                        return "$tool ✓"
                    }
                    if (status != ToolCallStatus.UNKNOWN) {
                        return "$tool (${status.summarySuffix})"
                    }
                    return tool
                }
            }

            ToolCallKind.WEB_SEARCH -> {
                val query = body.metadataValue("query")
                if (!query.isNullOrBlank()) {
                    return query
                }
            }

            ToolCallKind.IMAGE_VIEW -> {
                val path = body.metadataValue("path")
                if (!path.isNullOrBlank()) {
                    val basename = File(path).name.ifBlank { path }
                    return basename
                }
            }

            ToolCallKind.COLLABORATION -> {
                val tool = body.metadataValue("tool")
                if (!tool.isNullOrBlank()) {
                    return tool
                }
            }
        }

        if (!duration.isNullOrBlank() && status != ToolCallStatus.UNKNOWN) {
            return "$title (${status.summarySuffix}, $duration)"
        }
        if (status != ToolCallStatus.UNKNOWN) {
            return "$title (${status.summarySuffix})"
        }
        return title
    }

    private fun commandSummary(sections: List<ToolCallSection>): String? {
        sections.forEach { section ->
            when (section) {
                is ToolCallSection.Code -> {
                    if (normalizeToken(section.label) == "command") {
                        return section.content.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
                    }
                }

                is ToolCallSection.Text -> {
                    if (normalizeToken(section.label) == "command") {
                        return section.content.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
                    }
                }

                else -> Unit
            }
        }
        return null
    }

    private fun stripShellWrapper(command: String): String {
        var text = command.trim()
        val wrappers = listOf("/bin/zsh -lc '", "/bin/bash -lc '")
        wrappers.forEach { wrapper ->
            if (text.startsWith(wrapper) && text.endsWith("'")) {
                text = text.removePrefix(wrapper).removeSuffix("'")
            }
        }
        return text
    }

    private fun normalizeStatus(raw: String?): ToolCallStatus {
        val normalized = normalizeToken(raw.orEmpty())
        return when (normalized) {
            "inprogress", "in progress", "running", "pending", "started" -> ToolCallStatus.IN_PROGRESS
            "completed", "complete", "success", "ok", "done" -> ToolCallStatus.COMPLETED
            "failed", "failure", "error", "denied", "cancelled", "aborted" -> ToolCallStatus.FAILED
            else -> ToolCallStatus.UNKNOWN
        }
    }

    private fun parseSingleFence(text: String): ParsedFence? {
        val lines = text.split('\n')
        val first = lines.firstOrNull()?.trim() ?: return null
        val opening = openingFence(first) ?: return null

        val collected = mutableListOf<String>()
        var closed = false
        lines.drop(1).forEach { line ->
            if (isClosingFence(line.trim(), opening.marker, opening.length)) {
                closed = true
                return@forEach
            }
            if (!closed) {
                collected += line
            }
        }
        if (!closed) {
            return null
        }
        val language = first.drop(opening.length).trim()
        val content = collected.joinToString("\n").trim('\n')
        return ParsedFence(language = language, content = content)
    }

    private data class KeyValueParseResult(
        val key: String,
        val value: String,
    )

    private fun parseKeyValueLine(line: String): KeyValueParseResult? {
        val separator = line.indexOf(':')
        if (separator <= 0) {
            return null
        }
        val key = line.substring(0, separator).trim()
        val value = line.substring(separator + 1).trim()
        if (key.isBlank()) {
            return null
        }
        return KeyValueParseResult(key = key, value = value)
    }

    private data class HeaderParseResult(
        val label: String,
        val inlineValue: String,
    )

    private fun parseSectionHeader(line: String): HeaderParseResult? {
        val keyValue = parseKeyValueLine(line) ?: return null
        if (!namedSectionSet.contains(normalizeToken(keyValue.key))) {
            return null
        }
        return HeaderParseResult(label = keyValue.key, inlineValue = keyValue.value)
    }

    private data class OpeningFence(
        val marker: Char,
        val length: Int,
    )

    private fun openingFence(line: String): OpeningFence? {
        val marker = line.firstOrNull() ?: return null
        if (marker != '`' && marker != '~') {
            return null
        }
        val length = line.takeWhile { it == marker }.length
        if (length < 3) {
            return null
        }
        return OpeningFence(marker = marker, length = length)
    }

    private fun isClosingFence(
        line: String,
        marker: Char,
        minLength: Int,
    ): Boolean {
        if (line.firstOrNull() != marker) {
            return false
        }
        val length = line.takeWhile { it == marker }.length
        if (length < minLength) {
            return false
        }
        return line.drop(length).trim().isEmpty()
    }

    private fun updateFenceState(
        line: String,
        current: FenceState?,
    ): FenceState? {
        val trimmed = line.trim()
        if (current != null) {
            if (isClosingFence(trimmed, current.marker, current.length)) {
                return null
            }
            return current
        }
        val opening = openingFence(trimmed) ?: return null
        return FenceState(marker = opening.marker, length = opening.length)
    }

    private fun normalizeToken(value: String): String =
        value
            .trim()
            .lowercase(Locale.US)
            .replace(Regex("[^a-z0-9]+"), " ")
            .trim()

    private fun looksLikeJson(value: String): Boolean {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) {
            return false
        }
        if (trimmed.startsWith("{") && !trimmed.endsWith("}")) {
            return false
        }
        if (trimmed.startsWith("[") && !trimmed.endsWith("]")) {
            return false
        }
        return runCatching {
            if (trimmed.startsWith("{")) {
                JSONObject(trimmed)
            } else if (trimmed.startsWith("[")) {
                JSONArray(trimmed)
            } else {
                JSONArray("[$trimmed]")
            }
            true
        }.getOrElse { false }
    }
}
