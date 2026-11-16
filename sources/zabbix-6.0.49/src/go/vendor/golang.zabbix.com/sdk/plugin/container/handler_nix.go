//go:build !windows
// +build !windows

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

import (
	"net"
	"time"

	"golang.zabbix.com/sdk/errs"
)

func getConnection(path string, timeout time.Duration) (net.Conn, error) {
	t := time.NewTimer(timeout)
	defer t.Stop()

	for {
		select {
		case <-t.C:
			return nil, errs.Wrapf(
				ErrTimeout,
				"timeout occurred after %.2f seconds while trying to create a connection",
				timeout.Seconds(),
			)
		default:
			conn, err := net.DialTimeout("unix", path, timeout)
			if err != nil {
				continue
			}

			return conn, nil
		}
	}
}
