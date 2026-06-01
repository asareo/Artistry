package service

import (
	"net/http"
	"os"

	"github.com/NghiaTranUIT/artify-core/constant"
	"github.com/NghiaTranUIT/artify-core/resources"
	"github.com/NghiaTranUIT/artify-core/service/router"
	"github.com/labstack/echo"
	"github.com/labstack/echo/middleware"
)

type Service struct {
	echo   *echo.Echo
	router *router.Router
}

func New(r *resources.Resource) *Service {
	service := Service{
		echo:   echo.New(),
		router: &router.Router{R: r},
	}
	return &service
}

func (s *Service) Start() {
	echo := s.echo

	// Middleware
	echo.Use(middleware.Logger())
	echo.Use(middleware.Gzip())

	// Routes
	s.router.ApplyRoutes(echo)

	// Config
	port := os.Getenv("PORT")
	if port == "" {
		port = constant.AppPort
	}
	config := &http.Server{
		Addr: constant.AppHost + ":" + port,
	}

	// Start
	echo.Logger.Fatal(echo.StartServer(config))
}
