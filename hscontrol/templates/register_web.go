package templates

import (
	"fmt"

	"github.com/chasefleming/elem-go"
	"github.com/juanfont/headscale/hscontrol/types"
)

func RegisterWeb(registrationID types.RegistrationID) *elem.Element {
	return HtmlStructure(
		elem.Title(nil, elem.Text("Registration - Purr Hub")),
		mdTypesetBody(
			headscaleLogo(),
			H1(elem.Text("Machine registration")),
			P(elem.Text("Run the command below on the Purr Hub server to add this machine to your network:")),
			Pre(PreCode(fmt.Sprintf("purrhub nodes register --key %s --user USERNAME", registrationID.String()))),
			pageFooter(),
		),
	)
}
