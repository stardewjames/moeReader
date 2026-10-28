package moe.reader.suwayomi

import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList

/**
 * FilterList <-> the plain tree the app renders, with the same semantics as
 * the Swift engine's MihonFilters: identity is the positional path ("2.0.1")
 * because the list is rebuilt for every call, and selections are replayed onto
 * a fresh list before a search.
 *
 *   kind u8, name string, value string, ascending bool,
 *   entries list<string>, children list<filter>
 */
object Filters {
    const val HEADER = 0
    const val SEPARATOR = 1
    const val TEXT = 2
    const val CHECKBOX = 3
    const val TRISTATE = 4
    const val SELECT = 5
    const val SORT = 6
    const val GROUP = 7

    class Selection(
        val value: String,
        val ascending: Boolean,
    )

    fun write(
        writer: WireWriter,
        list: FilterList,
    ) {
        val items = list.toList()
        writer.i32(items.size)
        for (filter in items) write(writer, filter, 0)
    }

    private fun write(
        writer: WireWriter,
        filter: Any?,
        depth: Int,
    ) {
        if (filter !is Filter<*> || depth > 32) {
            writer.u8(HEADER).string("").string("").bool(true).i32(0).i32(0)
            return
        }
        var kind = HEADER
        var value = ""
        var ascending = true
        var entries: List<String> = emptyList()
        var children: List<*> = emptyList<Any>()
        when (filter) {
            is Filter.Header -> kind = HEADER
            is Filter.Separator -> kind = SEPARATOR
            is Filter.Text -> {
                kind = TEXT
                value = filter.state
            }
            is Filter.CheckBox -> {
                kind = CHECKBOX
                value = filter.state.toString()
            }
            is Filter.TriState -> {
                kind = TRISTATE
                value = filter.state.toString()
            }
            is Filter.Select<*> -> {
                kind = SELECT
                value = filter.state.toString()
                entries = filter.values.map { it.toString() }
            }
            is Filter.Sort -> {
                kind = SORT
                entries = filter.values.toList()
                filter.state?.let {
                    value = it.index.toString()
                    ascending = it.ascending
                }
            }
            is Filter.Group<*> -> {
                kind = GROUP
                children = filter.state
            }
        }
        writer
            .u8(kind)
            .string(filter.name)
            .string(value)
            .bool(ascending)
            .strings(entries)
            .i32(children.size)
        for (child in children) write(writer, child, depth + 1)
    }

    fun readSelections(reader: WireReader): Map<String, Selection> =
        reader.list { Triple(requireString(), requireString(), bool()) }.associate { (path, value, ascending) ->
            path to Selection(value, ascending)
        }

    fun apply(
        list: FilterList,
        selections: Map<String, Selection>,
    ) {
        if (selections.isEmpty()) return
        list.forEachIndexed { index, filter -> apply(filter, index.toString(), selections, 0) }
    }

    @Suppress("UNCHECKED_CAST")
    private fun apply(
        filter: Any?,
        path: String,
        selections: Map<String, Selection>,
        depth: Int,
    ) {
        if (filter !is Filter<*> || depth > 32) return
        if (filter is Filter.Group<*>) {
            filter.state.forEachIndexed { index, child -> apply(child, "$path.$index", selections, depth + 1) }
            return
        }
        val selection = selections[path] ?: return
        when (filter) {
            is Filter.Text -> filter.state = selection.value
            is Filter.CheckBox -> filter.state = selection.value == "true"
            is Filter.TriState -> filter.state = selection.value.toIntOrNull() ?: Filter.TriState.STATE_IGNORE
            is Filter.Select<*> -> {
                val index = selection.value.toIntOrNull() ?: 0
                (filter as Filter<Int>).state = index.coerceIn(0, (filter.values.size - 1).coerceAtLeast(0))
            }
            is Filter.Sort -> {
                val index = selection.value.toIntOrNull() ?: 0
                filter.state = Filter.Sort.Selection(index, selection.ascending)
            }
            else -> Unit
        }
    }
}
