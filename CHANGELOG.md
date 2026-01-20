# Changelog

## [Unreleased]

### Added
- ✅ MPVKit integration with full video playback support
- ✅ Frame extraction pipeline for buffering and OCR
- ✅ Disk buffer implementation for extended buffering (up to 40 minutes)
- ✅ Complete export functionality (frames, OCR text, composite images)
- ✅ Frame compression (JPEG) for memory efficiency
- ✅ Crash recovery with resume dialog
- ✅ Connection testing for stream URLs
- ✅ OCR bounding box visualization toggle
- ✅ Fullscreen support
- ✅ Window state persistence (size)
- ✅ Preferences integration (all settings wired up)

### Changed
- Updated implementation status to ~95% complete
- Reorganized documentation structure
- Improved error handling throughout

### Documentation
- Added comprehensive architecture documentation
- Created MPVKit integration guide
- Added development guide
- Updated README with documentation links

## Implementation Status

**Current Progress: ~95% Complete**

All core features from the original plan have been implemented:
- ✅ Video playback (all protocols)
- ✅ Frame buffering (RAM + disk)
- ✅ Focus scoring
- ✅ OCR text recognition
- ✅ Export functionality
- ✅ Crash recovery
- ✅ Preferences management
- ✅ Performance monitoring

### Remaining Items (Optional Enhancements)
- Tenengrad/Sobel focus algorithms (UI ready, implementation pending)
- Advanced render context optimization
- Additional export formats
