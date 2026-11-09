cask "pinga" do
  version "0.1.2"
  sha256 "dd631e565397dc65cc5a84280172ddc3401499141aba08ab49b5c47fbde1d863"

  url "https://github.com/sarangkharche/Pinga/releases/download/v#{version}/Pinga.zip"
  name "Pinga"
  desc "Notifications for GitHub pull requests"
  homepage "https://github.com/sarangkharche/Pinga"

  depends_on arch: :arm64
  depends_on formula: "gh"
  depends_on macos: :ventura

  app "Pinga.app"
end
