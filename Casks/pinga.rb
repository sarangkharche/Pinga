cask "pinga" do
  version "0.1.1"
  sha256 "57f8f0e092fedfd9b5fb0a811fd65b60208627294e7306c296f65ab5e5e55cdf"

  url "https://github.com/sarangkharche/Pinga/releases/download/v#{version}/Pinga.zip"
  name "Pinga"
  desc "Notifications for GitHub pull requests"
  homepage "https://github.com/sarangkharche/Pinga"

  depends_on arch: :arm64
  depends_on formula: "gh"
  depends_on macos: :ventura

  app "Pinga.app"
end
