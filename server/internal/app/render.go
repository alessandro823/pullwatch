package app

import (
	"net/http"

	"github.com/alessandro823/pullwatch/server/internal/web"
)

func renderPage(w http.ResponseWriter, name string, page web.Page) error {
	return web.Render(w, name, page)
}
