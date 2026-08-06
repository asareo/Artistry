package resources

import (
	"os/exec"
	"github.com/NghiaTranUIT/artify-core/models"
)

func (r *Resource) GetLatestFeaturePhoto() (*models.Photo, error) {

	// Get feature row for TODAY
	feature, err := r.GetFeatureOnDashboard()
	if err != nil {
		return nil, err
	}

	// Get author
	photo := models.Photo{}
	err = r.PostgreSQL.Eager("Author").Where("id = ?", feature.Photo.ID).First(&photo)
	if err != nil {
		return nil, err
	}

	// Has feature for today
	return &photo, nil
}

func (r *Resource) CreatePhotoByWikiart(param models.PhotoParam, author models.Author) (*models.Photo, error) {

	// Search first
	photo := models.Photo{}

	// Search photo by name firstly
	err := r.PostgreSQL.Where("name = ?", param.Name).First(&photo)

	// Create new photo
	if err != nil {
		newPhoto := models.Photo{
			Name:           param.Name,
			ImageUrl:       param.Url,
			Location:       param.Location,
			Dimensions:     "",
			Media:          param.Media,
			Style:          param.Style,
			Date:           param.Date,
			Info:           param.Info,
			Width:          uint(param.Width),
			Height:         uint(param.Height),
			AuthorID:       author.ID,
			OriginalSource: param.OriginalSource,
		}
		err = r.PostgreSQL.Eager("Author").Create(&newPhoto)
		if err != nil {
			return nil, err
		}
		return &newPhoto, nil
	}

	// Skip
	return &photo, nil
}

func (r *Resource) GetRandomPhoto() (*models.Photo, error) {
	photo := models.Photo{}

	// Exclude Art Institute of Chicago IIIF URLs — they block hotlinking (HTTP 403).
	// Only return photos from sources known to serve images directly:
	//   images.metmuseum.org  — Met Museum CDN (reliable)
	//   upload.wikimedia.org  — Wikimedia Commons (reliable)
	//   uploads*.wikiart.org  — WikiArt CDN (reliable)
	//   (curated hardcoded Wikipedia/other URLs also pass through)
	err := r.PostgreSQL.
		Eager("Author").
		Where("image_url NOT LIKE ?", "%www.artic.edu/iiif%").
		Order("random()").
		Limit(1).
		First(&photo)

	if err != nil {
		// Fallback: try any photo if filtering left nothing
		err = r.PostgreSQL.Eager("Author").Order("random()").Limit(1).First(&photo)
		if err != nil {
			return nil, err
		}
	}
	return &photo, nil
}

func (r *Resource) ToggleFavorite(photoID string) (*models.Photo, error) {
	photo := models.Photo{}
	err := r.PostgreSQL.Eager("Author").Find(&photo, photoID)
	if err != nil {
		return nil, err
	}
	photo.IsFavorite = !photo.IsFavorite
	err = r.PostgreSQL.Update(&photo)
	return &photo, err
}

func (r *Resource) GetFavorites() ([]models.Photo, error) {
	var photos []models.Photo
	err := r.PostgreSQL.Eager("Author").Where("is_favorite = ?", true).All(&photos)
	return photos, err
}

func (r *Resource) CreatePhoto(photo *models.Photo) error {
	return r.PostgreSQL.Create(photo)
}

func (r *Resource) SearchPhotos(query string, style string, nationality string) ([]models.Photo, error) {
	var photos []models.Photo
	c := r.PostgreSQL.Eager("Author")
	q := c.Where("1=1")

	if query != "" || nationality != "" {
		q = q.Join("authors a", "a.id = photos.author_id")
	}

	if query != "" {
		q = q.Where("(photos.name ILIKE ? OR a.name ILIKE ?)", "%"+query+"%", "%"+query+"%")
	}
	if style != "" {
		q = q.Where("photos.style ILIKE ?", "%"+style+"%")
	}
	if nationality != "" {
		q = q.Where("a.nationality ILIKE ?", "%"+nationality+"%")
	}

	err := q.All(&photos)
	return photos, err
}
func (r *Resource) Discovery(keyword string) (string, error) {
	cmd := exec.Command("python3", "scripts/discover_art.py", keyword)
	out, err := cmd.CombinedOutput()
	return string(out), err
}
