cask "pinga" do
  version "0.1.2"
  sha256 "d6c631463d105b303772cfde232c10a9e4437794c4a74289c70b3f58bd9a9117"

  url "https://github.com/sarangkharche/Pinga/releases/download/v#{version}/Pinga.zip"
  name "Pinga"
  desc "Notifications for GitHub pull requests"
  homepage "https://github.com/sarangkharche/Pinga"

  depends_on arch: :arm64
  depends_on formula: "gh"
  depends_on macos: :ventura

  app "Pinga.app"
end
