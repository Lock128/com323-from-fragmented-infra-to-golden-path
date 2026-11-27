// Entry point — the standard function-sdk-go gRPC server bootstrap.
package main

import (
	"github.com/alecthomas/kong"

	function "github.com/crossplane/function-sdk-go"
)

// CLI flags for the function server (standard across SDK functions).
type CLI struct {
	Debug bool `help:"Emit debug logs in addition to info logs." short:"d"`

	Network            string `default:"tcp"              help:"Network on which to listen for gRPC connections."`
	Address            string `default:":9443"            help:"Address at which to listen for gRPC connections."`
	TLSCertsDir        string `env:"TLS_SERVER_CERTS_DIR" help:"Directory containing server certs (tls.key, tls.crt) and the CA (ca.crt)."`
	Insecure           bool   `help:"Run without mTLS credentials. If set, --tls-server-certs-dir is ignored."`
	MaxRecvMessageSize int    `default:"4"                help:"Maximum size of received messages in MB."`
}

// Run the function.
func (c *CLI) Run() error {
	log, err := function.NewLogger(c.Debug)
	if err != nil {
		return err
	}
	return function.Serve(&Function{log: log},
		function.Listen(c.Network, c.Address),
		function.MTLSCertificates(c.TLSCertsDir),
		function.Insecure(c.Insecure),
		function.MaxRecvMessageSize(c.MaxRecvMessageSize*1024*1024))
}

func main() {
	ctx := kong.Parse(&CLI{}, kong.Description("function-observability — composes observability from tier × language."))
	ctx.FatalIfErrorf(ctx.Run())
}
