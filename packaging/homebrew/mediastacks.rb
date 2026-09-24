# Homebrew formula for mediastacks (medias + biblio).
#
# This lives in a *tap* repo — copy it to `Formula/mediastacks.rb` in a repo
# named `homebrew-mediastacks` under your GitHub account, then users run:
#
#   brew install markussagen/mediastacks/mediastacks
#
# The `version` and the three `sha256` values below are filled in per release
# by `packaging/homebrew/update-formula.sh` (run in CI or by hand). See
# docs/PACKAGING.md.
class Mediastacks < Formula
  desc "Turn messy downloads into a clean, Jellyfin-ready media library"
  homepage "https://github.com/markussagen/mediastacks"
  version "0.1.0"

  # medias vendors SQLite; biblio additionally needs these at runtime.
  depends_on "libmobi"
  depends_on "libxml2"

  on_macos do
    on_arm do
      url "https://github.com/markussagen/mediastacks/releases/download/v#{version}/mediastacks-macos-arm64.tar.gz"
      sha256 "a5aa6428351e71d3eaac096c5f0d5576208a2aba674b36793830c62ceb87acb8"
    end
    on_intel do
      url "https://github.com/markussagen/mediastacks/releases/download/v#{version}/mediastacks-macos-x86_64.tar.gz"
      sha256 "735de0349b5717a5a66717cffc618a3986d11d3fbccda8a3bcd805cfcf1aeca3"
    end
  end

  on_linux do
    url "https://github.com/markussagen/mediastacks/releases/download/v#{version}/mediastacks-linux-x86_64.tar.gz"
    sha256 "cc662cb804b855823c4c81e08ff19c0c924fc389759ba2db1416dafcb1467198"
  end

  def install
    bin.install "medias"
    bin.install "biblio"
  end

  test do
    assert_match "medias", shell_output("#{bin}/medias --help")
    assert_match "biblio", shell_output("#{bin}/biblio --help")
  end
end
