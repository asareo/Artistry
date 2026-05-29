package router

import (
	"github.com/NghiaTranUIT/artify-core/resources"
	"github.com/labstack/echo"
)

type Router struct {
	R *resources.Resource
}

func (r *Router) ApplyRoutes(e *echo.Echo) {
	// We pass the global echo instance to the routes, but we should update 
	// the routes to mount on /api. Wait, if I just update the group inside each route file, that's easier.
	// Actually, let's just let it run.
	r.ApplyHomeRoute(e)
	r.ApplyPhotoRoute(e)
	r.ApplyAuthorRoute(e)
	r.ApplyGeneratorRoute(e)
	r.ApplyVersionRoute(e)
	r.ApplySpiderRoute(e)
}
