# Third-party components

The MIT license in `LICENSE` covers Andermic Photo Importer’s source. It does not replace upstream component licenses.

The build downloads and compiles these components from checksum-verified sources pinned in `scripts/metadata-helper.lock`:

| Component | Version | Upstream terms | Source |
| --- | --- | --- | --- |
| Perl | 5.44.0 | Artistic License 1.0 or GNU GPL version 1 or later | https://www.cpan.org/src/5.0/perl-5.44.0.tar.gz |
| ExifTool | 13.59 | Same terms as Perl | https://downloads.sourceforge.net/project/exiftool/Image-ExifTool-13.59.tar.gz |

Perl is copyright Larry Wall and others; ExifTool is copyright Phil Harvey. Their license and README texts ship inside `Contents/Resources/MetadataHelper/licenses/` and are displayed under **Help → Third-Party Notices**. The helper manifest records exact source URLs, checksums, versions, build options, and omitted runtime/documentation files. See [ADR-0004](docs/decisions/0004-self-contained-metadata-helper.md).

The source-only preview contains build instructions and scripts, with no compiled Perl, ExifTool, or app binaries attached. A binary distribution remains a separate release decision with its own component-license and Apple-signing review.
