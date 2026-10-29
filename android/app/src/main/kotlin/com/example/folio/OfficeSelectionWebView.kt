package com.example.folio

import android.content.Context
import android.view.ActionMode
import android.view.ContextThemeWrapper
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.graphics.Rect
import android.webkit.WebView

/** Keep Chromium's selection, with application-owned handles and action pill.
 * Returning null/false from startActionMode would also disable native handles. */
internal class OfficeSelectionWebView(context: Context, ownedSelectionHandles: Boolean = false) : WebView(
    ContextThemeWrapper(context, if (ownedSelectionHandles) R.style.FolioOfficeOwnedSelectionTheme
        else R.style.FolioOfficeSelectionTheme),
) {
    private var selectionMode: ActionMode? = null
    var onSelectionInteractionCancelled: (() -> Unit)? = null

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) onSelectionInteractionCancelled?.invoke()
    }

    override fun onDetachedFromWindow() {
        onSelectionInteractionCancelled?.invoke()
        super.onDetachedFromWindow()
    }

    override fun startActionMode(callback: ActionMode.Callback): ActionMode? =
        startActionMode(callback, ActionMode.TYPE_FLOATING)

    override fun startActionMode(callback: ActionMode.Callback, type: Int): ActionMode? {
        val wrapper = object : ActionMode.Callback2() {
            override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
                val created = callback.onCreateActionMode(mode, menu)
                menu.clear()
                if (created) selectionMode = mode
                return created
            }

            override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
                callback.onPrepareActionMode(mode, menu)
                menu.clear()
                return true
            }

            override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean =
                callback.onActionItemClicked(mode, item)

            override fun onGetContentRect(mode: ActionMode, view: View, outRect: Rect) {
                if (callback is ActionMode.Callback2) callback.onGetContentRect(mode, view, outRect)
                else super.onGetContentRect(mode, view, outRect)
            }

            override fun onDestroyActionMode(mode: ActionMode) {
                if (selectionMode === mode) selectionMode = null
                callback.onDestroyActionMode(mode)
            }
        }
        return super.startActionMode(wrapper, type)
    }

    fun finishSelectionMode() {
        val mode = selectionMode
        selectionMode = null
        mode?.finish()
    }
}
