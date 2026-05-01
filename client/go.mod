module gitlab.com/ogamita/delta-ota/client

go 1.22

replace github.com/gabstv/go-bsdiff => ./internal/vendor/gabstv-go-bsdiff

replace github.com/dsnet/compress => ./internal/vendor/dsnet-compress

require github.com/gabstv/go-bsdiff v0.0.0-00010101000000-000000000000

require github.com/dsnet/compress v0.0.0-20171208185109-cc9eb1d7ad76 // indirect
