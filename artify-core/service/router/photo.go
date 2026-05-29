package router

import (
	"net/http"

	"github.com/NghiaTranUIT/artify-core/models"
	"github.com/labstack/echo"
)

func (r *Router) ApplyPhotoRoute(e *echo.Echo) {
	g := e.Group("/api/feature")
	g.GET("/today", r.getFeatureToday)
	g.GET("/random", r.getRandomPhoto)

	p := e.Group("/api/photos")
	p.POST("", r.createPhoto)
	p.POST("/:id/favorite", r.toggleFavorite)

	e.GET("/api/favorites", r.getFavorites)
	e.GET("/api/search/photos", r.searchPhotos)
	e.POST("/api/discover", r.discoverArt)
}

func (r *Router) getFeatureToday(c echo.Context) error {

	// Latest from DB
	photo, err := r.R.GetLatestFeaturePhoto()

	// Not found
	if photo == nil {
		return c.JSON(http.StatusOK, models.NewErrorResponse(err))
	}

	// Success
	return c.JSON(http.StatusOK, models.NewSuccessReponse(photo))
}

func (r *Router) getRandomPhoto(c echo.Context) error {
	photo, err := r.R.GetRandomPhoto()

	if err != nil {
		return c.JSON(http.StatusOK, models.NewErrorResponse(err))
	}
	return c.JSON(http.StatusOK, models.NewSuccessReponse(photo))
}

func (r *Router) createPhoto(c echo.Context) error {
	photo := models.Photo{}
	if err := c.Bind(&photo); err != nil {
		return c.JSON(http.StatusBadRequest, models.NewErrorResponse(err))
	}
	if err := r.R.CreatePhoto(&photo); err != nil {
		return c.JSON(http.StatusInternalServerError, models.NewErrorResponse(err))
	}
	return c.JSON(http.StatusOK, models.NewSuccessReponse(photo))
}

func (r *Router) toggleFavorite(c echo.Context) error {
	id := c.Param("id")
	photo, err := r.R.ToggleFavorite(id)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, models.NewErrorResponse(err))
	}
	return c.JSON(http.StatusOK, models.NewSuccessReponse(photo))
}

func (r *Router) getFavorites(c echo.Context) error {
	photos, err := r.R.GetFavorites()
	if err != nil {
		return c.JSON(http.StatusInternalServerError, models.NewErrorResponse(err))
	}
	return c.JSON(http.StatusOK, models.NewSuccessReponse(photos))
}

func (r *Router) searchPhotos(c echo.Context) error {
	query := c.QueryParam("q")
	style := c.QueryParam("style")
	nationality := c.QueryParam("nationality")

	photos, err := r.R.SearchPhotos(query, style, nationality)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, models.NewErrorResponse(err))
	}
	return c.JSON(http.StatusOK, models.NewSuccessReponse(photos))
}
func (r *Router) discoverArt(c echo.Context) error {
	keyword := c.QueryParam("q")
	if keyword == "" {
		return c.JSON(http.StatusBadRequest, models.NewErrorResponse(nil))
	}
	out, err := r.R.Discovery(keyword)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, models.NewErrorResponse(err))
	}
	return c.JSON(http.StatusOK, models.NewSuccessReponse(out))
}
