"""BirdJournal species pack builder (issue #8, spec "Pack builder").

Pipeline: pack definition -> iNaturalist metadata (Open Data CSVs or the API) -> license and quality filter ->
photo download from the Open Data bucket -> COCO bird detector -> crop scoring (bird area, background darkness,
sharpness) -> top 3-5 per species with overrides -> lens and phone JPEGs -> SQLite, LICENSE, report, zip.
"""
