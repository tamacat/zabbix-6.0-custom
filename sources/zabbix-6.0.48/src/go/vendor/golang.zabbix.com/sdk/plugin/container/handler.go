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
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"golang.zabbix.com/sdk/errs"
	"golang.zabbix.com/sdk/log"
	"golang.zabbix.com/sdk/plugin"
	"golang.zabbix.com/sdk/plugin/comms"
)

var (
	// ErrTimeout related to a timeout of some event.
	ErrTimeout = errs.New("timeout occurred")
)

// Handler provides means of handling plugins.
type Handler struct {
	name          string
	accessor      plugin.Accessor
	socket        string
	registerStart bool // true if the plugin has been started in its registration phase
	connection    net.Conn
}

// NewHandler takes in name of the plugin and returns handler for it.
func NewHandler(name string) (*Handler, error) {
	h := Handler{
		name: name,
	}

	if len(os.Args) < 2 {
		return &Handler{}, errs.New("no socket provided")
	}

	h.socket = os.Args[1]

	if len(os.Args) < 3 {
		h.registerStart = false

		return &h, nil
	}

	var err error

	h.registerStart, err = strconv.ParseBool(os.Args[2])
	if err != nil {
		return &Handler{}, errs.Wrap(err, "failed to parse third parameter")
	}

	return &h, nil
}

// Execute sets connection via socket and handles plugin operation according to data received.
func (h *Handler) Execute() error {
	conn, err := getConnection(h.socket, 3*time.Second)
	if err != nil {
		return errs.Wrap(err, "failed to set connection")
	}

	h.connection = conn

	h.accessor, err = plugin.GetByName(h.name)
	if err != nil {
		h.Errf("failed to get accessor for plugin %s, %s", h.name, err.Error())

		return errs.Wrap(err, "failed to get accessor")
	}

	go ignoreSIGINTandSIGTERM()

	for {
		done, err := h.handle()
		if err != nil {
			return errs.Wrap(err, "failed to handle request")
		}

		if done {
			break
		}
	}

	return nil
}

// Tracef sends a trace-level message with the given format and arguments.
func (h *Handler) Tracef(format string, args ...any) {
	h.sendLog(createLogRequest(log.Trace, fmt.Sprintf(format, args...)))
}

// Debugf sends a debug-level message with the given format and arguments.
func (h *Handler) Debugf(format string, args ...any) {
	h.sendLog(createLogRequest(log.Debug, fmt.Sprintf(format, args...)))
}

// Warningf sends a warning-level message with the given format and arguments.
func (h *Handler) Warningf(format string, args ...any) {
	h.sendLog(createLogRequest(log.Warning, fmt.Sprintf(format, args...)))
}

// Infof sends an informational message with the given format and arguments.
func (h *Handler) Infof(format string, args ...any) {
	h.sendLog(createLogRequest(log.Info, fmt.Sprintf(format, args...)))
}

// Errf sends an error-level message with the given format and arguments.
func (h *Handler) Errf(format string, args ...any) {
	h.sendLog(createLogRequest(log.Err, fmt.Sprintf(format, args...)))
}

// Critf sends a critical-level message with the given format and arguments.
func (h *Handler) Critf(format string, args ...any) {
	h.sendLog(createLogRequest(log.Crit, fmt.Sprintf(format, args...)))
}

// handle reads data from connection and processes it according to request type.
func (h *Handler) handle() (bool, error) { //nolint:gocyclo,cyclop
	meta, data, err := comms.Read(h.connection)
	if err != nil {
		return false, errs.Wrap(err, "failed to read request data")
	}

	h.Tracef("plugin %s executing %s request", h.name, comms.GetRequestName(meta.Type))

	switch meta.Type {
	case comms.RegisterRequestType:
		err = h.register(data)
		if err != nil {
			return false, errs.Wrap(err, "failed to register plugin")
		}
	case comms.StartRequestType:
		h.start()
	case comms.TerminateRequestType:
		h.stop()

		return true, nil
	case comms.ValidateRequestType:
		err = h.validate(data)
		if err != nil {
			return false, errs.Wrap(err, "failed to validate config")
		}
	case comms.ExportRequestType:
		go func() {
			err := h.export(data) //nolint:govet
			if err != nil {
				h.Errf("failed to handle request for plugin %s, %s", h.name, err.Error())

				return
			}

			h.Tracef("plugin %s export request completed", h.name)
		}()
	case comms.ConfigureRequestType:
		err = h.configure(data)
		if err != nil {
			return false, errs.Wrap(err, "failed to configure plugin")
		}
	default:
		return false, errs.Errorf("unknown request recivied: %d", meta.Type)
	}

	h.Tracef("plugin %s executed %s request", h.name, comms.GetRequestName(meta.Type))

	return false, nil
}

// start checks h.accessor is of type plugin.Runner and activates plugin.
func (h *Handler) start() {
	p, ok := h.accessor.(plugin.Runner)
	if !ok {
		return
	}

	p.Start()
}

// stop checks h.accessor is of type plugin.Runner and stops plugin.
func (h *Handler) stop() {
	if h.registerStart {
		return
	}

	p, ok := h.accessor.(plugin.Runner)
	if !ok {
		return
	}

	p.Stop()
}

func (h *Handler) validate(data []byte) error {
	var req comms.ValidateRequest

	err := json.Unmarshal(data, &req)
	if err != nil {
		return errs.Wrap(err, "failed to unmarshal validate request body")
	}

	response := createEmptyValidateResponse(req.Id)

	p, ok := h.accessor.(plugin.Configurator)
	if !ok {
		return errs.New("plugin does not implement Configurator interface")
	}

	err = p.Validate(req.PrivateOptions)
	if err != nil {
		response.Error = err.Error()
	}

	err = comms.Write(h.connection, response)
	if err != nil {
		return errs.Wrap(err, "failed to write response")
	}

	return nil
}

func (h *Handler) configure(data []byte) error {
	var req comms.ConfigureRequest

	err := json.Unmarshal(data, &req)
	if err != nil {
		return errs.Wrap(err, "failed to unmarshal configure request body")
	}

	p, ok := h.accessor.(plugin.Configurator)
	if !ok {
		return errs.New("plugin does not implement Configurator interface")
	}

	p.Configure(req.GlobalOptions, req.PrivateOptions)

	return nil
}

func (h *Handler) export(data []byte) error {
	var req comms.ExportRequest

	err := json.Unmarshal(data, &req)
	if err != nil {
		return errs.Wrap(err, "failed to unmarshal export request body")
	}

	p, ok := h.accessor.(plugin.Exporter)
	if !ok {
		return errs.New("plugin does not implement Exporter interface")
	}

	response := createEmptyExportResponse(req.Id)

	response.Value, err = p.Export(req.Key, req.Params, &emptyCtx{})
	if err != nil {
		response.Error = err.Error()
	}

	err = comms.Write(h.connection, response)
	if err != nil {
		return errs.Wrap(err, "failed to write response")
	}

	return nil
}

func (h *Handler) getInterfaces() uint32 {
	var interfaces uint32

	_, ok := h.accessor.(plugin.Exporter)
	if ok {
		interfaces |= comms.Exporter
	}

	_, ok = h.accessor.(plugin.Configurator)
	if ok {
		interfaces |= comms.Configurator
	}

	_, ok = h.accessor.(plugin.Runner)
	if ok {
		interfaces |= comms.Runner
	}

	return interfaces
}

func (h *Handler) sendLog(request comms.LogRequest) {
	err := comms.Write(h.connection, request)
	if err != nil {
		panic(fmt.Sprintf("failed to log message %s", err.Error()))
	}
}

func (h *Handler) register(data []byte) error {
	var req comms.RegisterRequest

	err := json.Unmarshal(data, &req)
	if err != nil {
		return errs.Wrap(err, "failed to unmarshal register request body")
	}

	response := createEmptyRegisterResponse(req.Id)

	err = h.checkVersion(req.ProtocolVersion, comms.ProtocolVersion)
	if err != nil {
		response.Error = err.Error()

		wErr := comms.Write(h.connection, response)
		if wErr != nil {
			return errs.Wrap(wErr, "failed to write response")
		}

		return errs.Wrap(err, "failed to check version")
	}

	metrics := make([]string, 0, 2*len(plugin.Metrics))

	for key, metric := range plugin.Metrics {
		metrics = append(metrics, key, metric.Description)
	}

	response.Name = h.name
	response.Metrics = metrics
	response.Interfaces = h.getInterfaces()

	err = comms.Write(h.connection, response)
	if err != nil {
		return errs.Wrap(err, "failed to write response")
	}

	return nil
}

func (h *Handler) checkVersion(agentProtocolVer, pluginProtocolVer string) error {
	if agentProtocolVer != pluginProtocolVer {
		return errs.Errorf(
			"Zabbix agent 2 protocol version %s does not match plugins '%s' protocol version %s",
			agentProtocolVer,
			h.name,
			pluginProtocolVer,
		)
	}

	return nil
}

func createLogRequest(severity uint32, message string) comms.LogRequest {
	return comms.LogRequest{
		Common: comms.Common{
			Id:   comms.NonRequiredID,
			Type: comms.LogRequestType,
		},
		Severity: severity,
		Message:  message,
	}
}

func createEmptyRegisterResponse(id uint32) comms.RegisterResponse {
	return comms.RegisterResponse{
		Common: comms.Common{
			Id:   id,
			Type: comms.RegisterResponseType,
		},
	}
}

func createEmptyExportResponse(id uint32) comms.ExportResponse {
	return comms.ExportResponse{
		Common: comms.Common{Id: id, Type: comms.ExportResponseType},
	}
}

func createEmptyValidateResponse(id uint32) comms.ValidateResponse {
	return comms.ValidateResponse{
		Common: comms.Common{Id: id, Type: comms.ValidateResponseType},
	}
}

func ignoreSIGINTandSIGTERM() {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	for {
		<-sigs
	}
}
