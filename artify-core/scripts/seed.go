package main

import (
	"fmt"
	"log"
	"strconv"

	"github.com/NghiaTranUIT/artify-core/constant"
	"github.com/NghiaTranUIT/artify-core/models"
	"github.com/NghiaTranUIT/artify-core/resources"
)

func main() {
	config := constant.Config{
		IsEnablePostgreSQL: true,
	}

	r, err := resources.Init(config)
	if err != nil {
		log.Fatalf("Failed to init resource: %v", err)
	}
	defer r.Close()

	csvPhotos, err := resources.ReadCSVFile("data.csv")
	if err != nil {
		log.Fatalf("Failed to read csv: %v", err)
	}

	fmt.Printf("Read %d photos from CSV\n", len(csvPhotos))

	for _, csvP := range csvPhotos {
		width, _ := strconv.Atoi(csvP.Width)
		height, _ := strconv.Atoi(csvP.Height)

		param := models.WikiartParam{
			Author: models.AuthorParam{
				Name:        csvP.AuthorName,
				Born:        csvP.Born,
				Died:        csvP.Died,
				Nationality: csvP.Nationality,
				Wikipedia:   csvP.Wikipedia,
			},
			Photo: models.PhotoParam{
				Name:     csvP.Name,
				Date:     csvP.Date,
				Style:    csvP.Style,
				Media:    csvP.Media,
				Location: csvP.Location,
				Info:     csvP.Info,
				Url:      csvP.ImageURL,
				Width:    width,
				Height:   height,
			},
		}

		// Because AuthorParam might miss some mappings from CSV, let's just use CreatePhotoAuthorFromWikiart
		photo, err := r.CreatePhotoAuthorFromWikiart(param)
		if err != nil {
			log.Printf("Failed to create %s: %v", csvP.Name, err)
		} else {
			log.Printf("Created photo %s by %s", photo.Name, photo.Author.Name)
		}
	}
}
