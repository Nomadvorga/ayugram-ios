import CoreLocation
import MapKit
import SGSimpleSettings
import UIKit

/// Manual map selection does not ask for device location. Only Save persists it.
final class ExteraPillWeatherSettingsController: UIViewController, MKMapViewDelegate, UISearchBarDelegate {
    private let account: Int64
    private let language: String
    private let map = MKMapView()
    private let search = UISearchBar()
    private let mode = UISegmentedControl(items: ["Current Location", "Select Location"])
    private let address = UILabel()
    private var value: ExteraPillWeather
    private var searchRequest: MKLocalSearch?
    private var revision = 0
    init(account: Int64, language: String) {
        self.account = account; self.language = language
        self.value = ExteraPillStackSettings.shared.weather(account: account)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { preconditionFailure() }
    deinit { self.searchRequest?.cancel() }
    private func text(_ en: String, _ ru: String) -> String { exteraPillText(self.language, en, ru) }
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.mode.setTitle(self.text("Current Location", "Текущая геопозиция"), forSegmentAt: 0)
        self.mode.setTitle(self.text("Select Location", "Выбрать место"), forSegmentAt: 1)
        self.mode.selectedSegmentIndex = self.value.current ? 0 : 1
        self.mode.addTarget(self, action: #selector(self.modeChanged), for: .valueChanged)
        self.map.delegate = self; self.map.showsUserLocation = false
        self.search.delegate = self; self.search.placeholder = self.text("Search location", "Поиск места")
        self.address.numberOfLines = 0; self.address.text = self.value.address
        let save = UIButton(type: .system); save.setTitle(self.text("Save", "Сохранить"), for: .normal); save.addTarget(self, action: #selector(self.save), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle(self.text("Cancel", "Отмена"), for: .normal); cancel.addTarget(self, action: #selector(self.cancel), for: .touchUpInside)
        let locationSettings = UIButton(type: .system); locationSettings.setTitle(self.text("Location Settings", "Настройки геопозиции"), for: .normal); locationSettings.addTarget(self, action: #selector(self.openLocationSettings), for: .touchUpInside)
        let content = UIStackView(arrangedSubviews: [self.mode, self.search, self.map, self.address, locationSettings, save, cancel])
        content.axis = .vertical; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 16), content.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -16), content.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 16), content.bottomAnchor.constraint(lessThanOrEqualTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -16), self.map.heightAnchor.constraint(equalToConstant: 240)])
        self.map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: self.value.latitude, longitude: self.value.longitude), latitudinalMeters: 8000, longitudinalMeters: 8000), animated: false)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(self.pick(_:))); self.map.addGestureRecognizer(press)
        self.modeChanged()
    }
    @objc private func modeChanged() {
        self.value.current = self.mode.selectedSegmentIndex == 0
        self.map.isHidden = self.value.current; self.search.isHidden = self.value.current; self.address.isHidden = self.value.current
    }
    @objc private func pick(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        self.select(self.map.convert(gesture.location(in: self.map), toCoordinateFrom: self.map))
    }
    private func select(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        self.revision += 1
        self.value.latitude = coordinate.latitude; self.value.longitude = coordinate.longitude; self.value.address = ""
        self.map.removeAnnotations(self.map.annotations)
        let pin = MKPointAnnotation(); pin.coordinate = coordinate; self.map.addAnnotation(pin)
        self.address.text = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder(); self.searchRequest?.cancel()
        guard let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return }
        self.revision += 1; let revision = self.revision
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query; request.region = self.map.region
        let search = MKLocalSearch(request: request); self.searchRequest = search
        search.start { [weak self] result, _ in
            guard let self, self.revision == revision, let result, !result.mapItems.isEmpty else { return }
            let picker = UIAlertController(title: self.text("Search Results", "Результаты поиска"), message: nil, preferredStyle: .actionSheet)
            for item in result.mapItems.prefix(8) {
                let name = item.name ?? query
                picker.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                    guard let self else { return }
                    let coordinate = self.coordinate(for: item)
                    self.map.setCenter(coordinate, animated: true)
                    self.select(coordinate)
                    self.value.address = String(name.prefix(512))
                    self.address.text = self.value.address
                })
            }
            picker.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
            picker.popoverPresentationController?.sourceView = self.search
            picker.popoverPresentationController?.sourceRect = self.search.bounds
            self.present(picker, animated: true)
        }
    }
    private func coordinate(for item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26.0, *) {
            return item.location.coordinate
        } else {
            return self.legacyCoordinate(for: item)
        }
    }
    @available(iOS, deprecated: 26.0, message: "Use MKMapItem.location on iOS 26 and later")
    private func legacyCoordinate(for item: MKMapItem) -> CLLocationCoordinate2D {
        return item.placemark.coordinate
    }
    @objc private func save() { ExteraPillStackSettings.shared.setWeather(self.value, account: self.account); self.dismiss(animated: true) }
    @objc private func cancel() { self.dismiss(animated: true) }
    @objc private func openLocationSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
