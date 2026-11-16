/*
** Zabbix
** Copyright (C) 2001-2026 Zabbix SIA
**
** Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
** documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
** rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
** permit persons to whom the Software is furnished to do so, subject to the following conditions:
**
** The above copyright notice and this permission notice shall be included in all copies or substantial portions
** of the Software.
**
** THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
** WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
** COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
** TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
** SOFTWARE.
**/

package container

import "golang.zabbix.com/sdk/plugin"

var (
	_ plugin.ContextProvider = (*emptyCtx)(nil)
	_ plugin.RegexpMatcher   = (*emptyMatcher)(nil)
	_ plugin.ResultWriter    = (*emptyResultWriter)(nil)
)

type emptyCtx struct{}

type emptyMatcher struct{}

type emptyResultWriter struct{}

// ClientID always return 0.
func (*emptyCtx) ClientID() uint64 {
	return 0
}

// ItemID always return 0.
func (*emptyCtx) ItemID() uint64 {
	return 0
}

// Output returns the result writer for emptyCtx.
func (*emptyCtx) Output() plugin.ResultWriter { //nolint:ireturn
	return &emptyResultWriter{}
}

// Meta returns the meta information, which is nil for emptyCtx.
func (*emptyCtx) Meta() *plugin.Meta {
	return nil
}

// GlobalRegexp made so emptyCtx satisfies plugin.ContextProvider interface.
// Returns emptyMatcher.
func (*emptyCtx) GlobalRegexp() plugin.RegexpMatcher { //nolint:ireturn
	return &emptyMatcher{}
}

// Delay returns the delay, which is an empty string for emptyCtx.
func (*emptyCtx) Delay() string {
	return ""
}

// Match is function for emptyMatcher to implement plugin.RegexpMatcher interface.
// Always returns false and empty string.
func (*emptyMatcher) Match(value, pattern string, mode int, outputTemplate *string) (bool, string) { //nolint:revive
	return false, ""
}

// Write is implementation of the Write receiver from the plugin.ResultWriter interface.
func (*emptyResultWriter) Write(*plugin.Result) {}

// Flush is implementation of the Flush receiver from the plugin.ResultWriter interface.
func (*emptyResultWriter) Flush() {}

// SlotsAvailable always returns 0.
func (*emptyResultWriter) SlotsAvailable() int { return 0 }

// PersistSlotsAvailable always returns 0.
func (*emptyResultWriter) PersistSlotsAvailable() int { return 0 }
