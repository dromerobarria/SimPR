# Homebrew cask for SimPR. Publish it in a tap repository named
# dromerobarria/homebrew-simpr (Casks/simpr.rb) so users can run:
#   brew install --cask dromerobarria/simpr/simpr
cask "simpr" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/dromerobarria/SimPR/releases/download/mac-v#{version}/SimPR-#{version}.dmg"
  name "SimPR"
  desc "Run iOS pull request builds in the Simulator with one click"
  homepage "https://github.com/dromerobarria/SimPR"

  livecheck do
    url :url
    regex(/^mac-v?(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  depends_on macos: ">= :sonoma"

  app "SimPR.app"

  zap trash: [
    "~/Library/Application Support/SimPR",
    "~/Library/Preferences/dev.danielromero.SimPR.plist",
  ]

  caveats <<~EOS
    SimPR needs Xcode with at least one iOS Simulator runtime installed.
  EOS
end
