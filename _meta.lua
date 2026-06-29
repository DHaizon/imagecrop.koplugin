local _ = require("gettext")
return {
    name     = "imagecrop",
    fullname = _("Image Crop"),
    description = _([[Adds a "Crop" button to the ImageViewer.
Select an area with drag handles, then tap "Crop & Save" to
save the cropped region as a new PNG file.]]),
}
