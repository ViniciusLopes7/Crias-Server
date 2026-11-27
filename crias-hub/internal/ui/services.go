package ui

import "github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"

func serviceRows(r metrics.Reading[[]metrics.ServiceStatus]) []line {
	rows := []line{{"Serviços systemd · somente leitura", heading}}
	if r.State != metrics.Available {
		return append(rows, line{"Estado: " + availability(r.State), muted})
	}
	for _, v := range r.Data {
		label := deviceLabel(v.Unit) + ": "
		if v.State != metrics.Available {
			rows = append(rows, line{label + availability(v.State), muted})
			continue
		}
		// Load and activation are different systemd properties.
		rows = append(rows, line{label + deviceLabel(v.Load) + " / " + deviceLabel(v.Active) + " / " + deviceLabel(v.Sub), normal})
	}
	return append(rows, line{"Ativo não confirma conexão ou jogo disponível.", muted})
}
