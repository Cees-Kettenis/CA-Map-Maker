# Map updates

New community links fetch their group and upcoming meetups in the background. Pasted meetup links fetch once when you create a map. Communities and unfinished meetups then update once a day, even while your browser is closed.

Open **Updates** beside **Export KML** to see **Last updated**, **Scheduled update** and **Update now**. Select **Update now** to queue a fetch immediately instead of waiting for the daily schedule. Existing meetups stay visible during updates. Internal batch numbers are not shown.

Creating a date map from communities refreshes the selected events' details. These maps read the communities' saved event records directly, so details and locally stored images are shared. Events moved to another day leave the date map automatically.

Large automatic imports still process up to 50 links per account in each 10-minute scheduling window. This is a queue limit, not a recurring fetch interval. Failed event requests can retry up to three times. Finished meetups are excluded from automatic detail updates.

Images are downloaded once per distinct URL. Viewing or refreshing a page uses the local copies. Failed image downloads are not retried automatically.

If your token expired, [replace it](campfire-credentials.md) before updating. See [troubleshooting](troubleshooting.md) for other failures.
